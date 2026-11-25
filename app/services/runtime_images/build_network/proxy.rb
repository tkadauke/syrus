require "socket"
require "uri"
require "fileutils"

module RuntimeImages
  module BuildNetwork
    # The only egress a build has. It listens on a Unix socket (bridged into
    # the build's empty network namespace by bin/runtime-image-build-relay) and
    # speaks the two things package managers use: CONNECT tunnels and
    # absolute-form plain HTTP requests.
    #
    # Every request is decided by the Policy, then resolved by the Resolver,
    # and the proxy dials the validated address itself. It never follows
    # redirects: a 3xx whose target is not allowlisted is replaced by a 403.
    # Anything it does not understand is refused, not passed through.
    class Proxy
      MAX_HEAD_BYTES = 16 * 1024
      MAX_RESPONSE_HEAD_BYTES = 64 * 1024
      MAX_REQUEST_BODY_BYTES = 16 * 1024 * 1024
      HEAD_TIMEOUT = 10
      CONNECT_TIMEOUT = 10
      MAX_RECORDED_DENIALS = 25
      HOP_BY_HOP = %w[connection keep-alive te trailer upgrade host content-length expect transfer-encoding
                      proxy-connection proxy-authorization proxy-authenticate].freeze
      HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

      class Refused < Error
        attr_reader :status, :reason

        def initialize(status, reason)
          @status = status
          @reason = reason
          super("#{status} #{reason}")
        end
      end

      attr_reader :socket_path

      def initialize(policy:, socket_path:, resolver: Resolver.new, max_connections: 32, idle_timeout: 60, connector: nil)
        @policy = policy
        @socket_path = socket_path.to_s
        @resolver = resolver
        @max_connections = max_connections
        @idle_timeout = idle_timeout
        @connector = connector || ->(address, port) { Socket.tcp(address, port, connect_timeout: CONNECT_TIMEOUT) }
        @mutex = Mutex.new
        @clients = []
        @allowed = 0
        @denied = 0
        @denials = {}
        @destinations = {}
      end

      def start
        FileUtils.rm_f(@socket_path)
        @server = UNIXServer.new(@socket_path)
        File.chmod(0o600, @socket_path)
        @acceptor = Thread.new { accept_loop }
        @acceptor.report_on_exception = false
        self
      end

      def stop
        @server&.close
        @acceptor&.kill
        @mutex.synchronize { @clients.dup }.each { |client| close(client) }
        FileUtils.rm_f(@socket_path)
      end

      def summary
        @mutex.synchronize do
          { "policy_digest" => @policy.digest, "allowed" => @allowed, "denied" => @denied,
            "denials" => @denials.map { |(host, port, reason), count| { "host" => host, "port" => port, "reason" => reason, "count" => count } },
            "destinations" => @destinations.map do |(host, port, address, source_class), count|
              { "host" => host, "port" => port, "address" => address, "source_class" => source_class, "count" => count }
            end }
        end
      end

      private

      def accept_loop
        loop do
          client = @server.accept
          unless admit(client)
            refuse_quietly(client, 503, "proxy_busy")
            next
          end
          thread = Thread.new(client) { |socket| serve(socket) }
          thread.report_on_exception = false
        end
      rescue IOError, SystemCallError
        nil
      end

      def admit(client)
        @mutex.synchronize do
          return false if @clients.size >= @max_connections

          @clients << client
          true
        end
      end

      def serve(client)
        head, leftover = read_head(client, MAX_HEAD_BYTES, HEAD_TIMEOUT)
        request_line, *lines = head.split("\r\n")
        method, target, version = request_line.to_s.split(" ", 3)
        raise Refused.new(400, "malformed_request") unless method&.match?(/\A[A-Z]{3,10}\z/) && target && version&.start_with?("HTTP/1.")

        method == "CONNECT" ? tunnel(client, target, leftover) : forward(client, method, target, lines, leftover)
      rescue Refused => e
        respond(client, e.status, e.reason)
      rescue StandardError => e
        Rails.logger.warn("[RuntimeImages::BuildNetwork::Proxy] #{e.class}: #{e.message}")
        respond(client, 502, "proxy_error")
      ensure
        close(client)
        @mutex.synchronize { @clients.delete(client) }
      end

      def tunnel(client, target, leftover)
        host, port = parse_authority(target)
        address = authorize(@policy.decide(host: host, port: port))
        upstream = dial(address, port)
        begin
          client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
          upstream.write(leftover) unless leftover.empty?
          pipe(client, upstream)
        ensure
          close(upstream)
        end
      end

      def forward(client, method, target, lines, leftover)
        uri = parse_http_target(target)
        host = uri.host.to_s
        port = uri.port
        path = uri.path.empty? ? "/" : uri.path
        address = authorize(@policy.decide(host: host, port: port, path: path))
        headers = parse_headers(lines)
        length = request_body_length(headers)
        upstream = dial(address, port)
        begin
          upstream.write(upstream_head(method, uri, headers, length))
          send_body(client, upstream, leftover, length)
          relay_response(client, upstream, uri)
        ensure
          close(upstream)
        end
      end

      # Resolves the host once and returns a validated address to dial, or
      # raises Refused. The policy decision is recorded either way.
      def authorize(decision)
        unless decision.allowed?
          record(decision)
          raise Refused.new(403, decision.reason)
        end

        address = @resolver.resolve(decision.host, allow_private: decision.allow_private).first
        record(decision, address: address)
        address
      rescue Resolver::Blocked => e
        record(Decision.deny(e.reason, host: decision.host, port: decision.port))
        raise Refused.new(403, e.reason)
      end

      def dial(address, port)
        @connector.call(address, port)
      rescue SystemCallError, IOError, Timeout::Error
        raise Refused.new(502, "upstream_unreachable")
      end

      def parse_authority(target)
        host, separator, port = target.rpartition(":")
        raise Refused.new(400, "malformed_request") if separator.empty? || !port.match?(/\A\d{1,5}\z/)

        [ host, Integer(port, 10) ]
      end

      def parse_http_target(target)
        raise Refused.new(400, "absolute_uri_required") unless target.match?(%r{\Ahttp://}i)

        uri = URI.parse(target)
        raise Refused.new(400, "malformed_request") if uri.host.blank? || uri.userinfo
        raise Refused.new(403, "invalid_host") if uri.host.match?(/[%\s]/)

        uri
      rescue URI::InvalidURIError
        raise Refused.new(400, "malformed_request")
      end

      def parse_headers(lines)
        lines.map do |line|
          name, separator, value = line.partition(":")
          raise Refused.new(400, "malformed_header") if separator.empty? || !name.match?(HEADER_NAME)

          [ name, value.strip ]
        end
      end

      def request_body_length(headers)
        raise Refused.new(501, "chunked_request_unsupported") if headers.any? { |name, _| name.casecmp?("transfer-encoding") }

        lengths = headers.select { |name, _| name.casecmp?("content-length") }.map(&:last)
        return 0 if lengths.empty?
        raise Refused.new(400, "malformed_header") unless lengths.uniq.one? && lengths.first.match?(/\A\d{1,10}\z/)

        length = lengths.first.to_i
        raise Refused.new(413, "request_body_too_large") if length > MAX_REQUEST_BODY_BYTES

        length
      end

      def upstream_head(method, uri, headers, length)
        host = uri.port == 80 ? uri.host : "#{uri.host}:#{uri.port}"
        out = [ "#{method} #{uri.request_uri} HTTP/1.1", "Host: #{host}", "Connection: close" ]
        headers.each { |name, value| out << "#{name}: #{value}" unless HOP_BY_HOP.include?(name.downcase) }
        out << "Content-Length: #{length}" if length.positive?
        "#{out.join("\r\n")}\r\n\r\n"
      end

      def send_body(client, upstream, leftover, length)
        remaining = length
        chunk = leftover.byteslice(0, remaining).to_s
        upstream.write(chunk) unless chunk.empty?
        remaining -= chunk.bytesize
        while remaining.positive?
          raise Refused.new(408, "client_timeout") unless IO.select([ client ], nil, nil, @idle_timeout)

          data = client.read_nonblock([ remaining, 16_384 ].min, exception: false)
          raise Refused.new(400, "truncated_body") if data.nil?
          next if data == :wait_readable

          upstream.write(data)
          remaining -= data.bytesize
        end
      end

      def relay_response(client, upstream, uri)
        head, body = read_head(upstream, MAX_RESPONSE_HEAD_BYTES, @idle_timeout)
        status_line, *lines = head.split("\r\n")
        status = status_line.to_s[%r{\AHTTP/1\.[01] (\d{3})}, 1].to_i
        raise Refused.new(502, "malformed_upstream_response") if status.zero?

        check_redirect(status, lines, uri)
        client.write("#{head}\r\n\r\n")
        client.write(body) unless body.empty?
        pipe_one_way(upstream, client)
      end

      # The proxy never follows a redirect, but the client will. A redirect to
      # a destination the client could not have asked for directly is stopped
      # here with a clear reason instead of failing later in a tunnel.
      def check_redirect(status, lines, uri)
        return unless (300..399).cover?(status)

        location = lines.filter_map { |line| line.split(":", 2).last.strip if line.downcase.start_with?("location:") }.first
        return if location.nil?

        target = URI.join(uri.to_s, location)
        port = target.port || (target.scheme == "https" ? 443 : 80)
        decision = @policy.decide(host: target.host.to_s, port: port, path: target.path.empty? ? "/" : target.path)
        return if decision.allowed?

        record(Decision.deny("redirect_not_allowlisted", host: decision.host, port: decision.port))
        raise Refused.new(403, "redirect_not_allowlisted")
      rescue URI::Error
        record(Decision.deny("redirect_not_allowlisted", host: uri.host.to_s, port: uri.port))
        raise Refused.new(403, "redirect_not_allowlisted")
      end

      # Reads up to the blank line ending an HTTP head. Returns [head, extra]
      # where extra is whatever arrived after it.
      def read_head(io, limit, timeout)
        buffer = +"".b
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        until (index = buffer.index("\r\n\r\n"))
          raise Refused.new(431, "head_too_large") if buffer.bytesize > limit

          wait = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Refused.new(408, "head_timeout") unless wait.positive? && IO.select([ io ], nil, nil, wait)

          data = io.read_nonblock(4096, exception: false)
          raise Refused.new(400, "truncated_request") if data.nil?
          buffer << data unless data == :wait_readable
        end
        head = buffer.byteslice(0, index)
        raise Refused.new(400, "malformed_request") if head.match?(/(?<!\r)\n|\0|\r(?!\n)|\r\n[ \t]/n)

        [ head.force_encoding(Encoding::UTF_8).scrub, buffer.byteslice(index + 4, buffer.bytesize).to_s ]
      end

      def pipe(a, b)
        peers = { a => b, b => a }
        loop do
          ready = IO.select(peers.keys, nil, nil, @idle_timeout)
          return if ready.nil?

          ready.first.each do |io|
            data = io.read_nonblock(16_384, exception: false)
            return if data.nil?
            next if data == :wait_readable

            peers.fetch(io).write(data)
          end
        end
      rescue IOError, SystemCallError
        nil
      end

      def pipe_one_way(from, to)
        loop do
          return unless IO.select([ from ], nil, nil, @idle_timeout)

          data = from.read_nonblock(16_384, exception: false)
          return if data.nil?
          next if data == :wait_readable

          to.write(data)
        end
      rescue IOError, SystemCallError
        nil
      end

      def record(decision, address: nil)
        @mutex.synchronize do
          if decision.allowed?
            @allowed += 1
            key = [ decision.host, decision.port, address.to_s, decision.source_class.to_s ]
            @destinations[key] = @destinations.fetch(key, 0) + 1 if @destinations.key?(key) || @destinations.size < MAX_RECORDED_DENIALS
          else
            @denied += 1
            key = [ decision.host, decision.port, decision.reason ]
            @denials[key] = @denials.fetch(key, 0) + 1 if @denials.key?(key) || @denials.size < MAX_RECORDED_DENIALS
          end
        end
      end

      def respond(client, status, reason)
        body = "build network request denied: #{reason}\n"
        client.write("HTTP/1.1 #{status} #{status == 403 ? 'Forbidden' : 'Error'}\r\nX-Build-Network-Denied: #{reason}\r\n" \
                     "Content-Type: text/plain\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      rescue IOError, SystemCallError
        nil
      end

      def refuse_quietly(client, status, reason)
        respond(client, status, reason)
        close(client)
      end

      def close(io)
        io&.close unless io&.closed?
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
