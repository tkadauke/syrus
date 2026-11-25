require "base64"
require "faraday"
require "fileutils"
require "open3"
require "openssl"
require "socket"
require "securerandom"
require "tmpdir"
require "uri"

module ManualAgenticRun
  # Run-scoped broker. Agent-visible wrappers know only a local socket; the
  # credential and authoritative audit buffer remain in the worker process.
  class GithubAccess
    PERMISSIONS = { contents: "write", pull_requests: "write", issues: "write" }.freeze
    DESTRUCTIVE_GH = /\Aapi .*\s(?:-X|--method)(?:=|\s)+(?:DELETE|PUT)/i
    REGISTRY = {}
    REGISTRY_MUTEX = Mutex.new

    def self.for(run) = new(run)

    def self.cleanup(run)
      REGISTRY_MUTEX.synchronize { REGISTRY.delete(run.id) }&.stop
      dir = run.step.workflow.artifact("manual_agentic_run_github_wrapper_dir")
      FileUtils.remove_entry_secure(dir) if dir.present? && File.directory?(dir)
      run.step.workflow.set_artifact!("manual_agentic_run_github_wrapper_dir", nil) if dir.present?
    rescue StandardError => e
      Rails.logger.warn("[ManualAgenticRun::GithubAccess] cleanup failed: #{e.class}: #{CommandRedactor.redact(e.message)}")
    end

    def initialize(run)
      @run = run
      @workflow = run.step.workflow
      @job = @workflow.job
      @repository = @job.repository
    end

    def enabled? = @workflow.artifact("manual_agentic_run_github_access") == true

    def environment
      return {} unless enabled?
      installation = @repository.installation
      raise ArgumentError, "break-glass GitHub access requires an active GitHub App installation" unless installation&.active? && installation.covers_repository?(@repository)
      raise ArgumentError, "repository GitHub id is required for scoped access" if @repository.github_repository_id.blank?

      grant = installation.scoped_token(repository: @repository, permissions: PERMISSIONS)
      raise ArgumentError, "scoped GitHub credential is already expired" unless grant.fetch(:expires_at) > Time.current
      dir = Dir.mktmpdir("syrus-github-run-#{@run.id}-")
      socket_path = File.join(dir, "broker.sock")
      broker = Broker.new(socket_path:, proxy_dir: dir, token: grant.fetch(:token), expires_at: grant.fetch(:expires_at), repository: @repository.slug,
        destructive: @workflow.artifact("manual_agentic_run_github_destructive") == true,
        commands: { "gh" => real_command("gh"), "git" => real_command("git") }).start
      self.class::REGISTRY_MUTEX.synchronize do
        raise "break-glass GitHub broker already exists for Run #{@run.id}" if self.class::REGISTRY.key?(@run.id)
        self.class::REGISTRY[@run.id] = broker
      end
      %w[gh git].each { |name| write_wrapper(dir, name, socket_path) }
      @workflow.set_artifact!("manual_agentic_run_github_wrapper_dir", dir)
      @workflow.set_artifact!("manual_agentic_run_github_credential_expires_at", grant.fetch(:expires_at).iso8601)
      { "PATH" => "#{dir}:#{ENV.fetch('PATH', '')}", "GH_HOST" => "github.com", "GH_REPO" => @repository.slug,
        "SYRUS_GITHUB_REPOSITORY" => @repository.slug }
    rescue StandardError
      broker&.stop
      FileUtils.remove_entry_secure(dir) if dir.present? && File.directory?(dir)
      raise
    end

    def collect_audit!
      broker = self.class::REGISTRY_MUTEX.synchronize { self.class::REGISTRY[@run.id] }
      entries = broker&.audit_entries || []
      @workflow.set_artifact!("manual_agentic_run_github_audit", entries.map { |entry| entry.merge("actor_user_id" => @job.user_id, "repository" => @repository.slug) })
      entries
    end

    private

    def real_command(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |part| File.join(part, name) }.find { |path| File.file?(path) && File.executable?(path) } || raise(ArgumentError, "#{name} is unavailable on this worker")
    end

    def write_wrapper(dir, name, socket_path)
      source = <<~RUBY
        #!/usr/bin/env ruby
        require "json"; require "socket"
        socket = UNIXSocket.new(#{socket_path.inspect})
        socket.puts(JSON.generate(command: #{name.inspect}, args: ARGV, cwd: Dir.pwd))
        response = JSON.parse(socket.read)
        $stdout.write(response.fetch("stdout", "")); $stderr.write(response.fetch("stderr", ""))
        exit Integer(response.fetch("exit_status", 1))
      RUBY
      File.write(File.join(dir, name), source, mode: "w", perm: 0o700)
    end

    class Broker
      def initialize(socket_path:, proxy_dir:, token:, expires_at:, repository:, destructive:, commands:)
        @socket_path, @token, @expires_at, @repository = socket_path, token, expires_at, repository
        @proxy_dir = proxy_dir
        @destructive, @commands = destructive, commands
        @audit_entries, @audit_mutex = [], Mutex.new
      end

      def start
        @proxy = CredentialProxy.new(
          dir: @proxy_dir, token: @token, repository: @repository, destructive: @destructive,
          on_request: method(:record_proxy_request)
        ).start
        @server = UNIXServer.new(@socket_path)
        File.chmod(0o600, @socket_path)
        @thread = Thread.new { serve }
        self
      end

      def stop
        @server&.close
        @thread&.join(1)
      rescue IOError, Errno::EBADF
        nil
      ensure
        @proxy&.stop
        @token = nil
      end

      def audit_entries = @audit_mutex.synchronize { @audit_entries.map(&:dup) }

      private

      def serve
        loop do
          client = @server.accept
          request = JSON.parse(client.gets.to_s)
          client.write(JSON.generate(execute(request)))
        rescue IOError, Errno::EBADF
          break
        rescue StandardError => e
          client&.write(JSON.generate(stdout: "", stderr: "Syrus GitHub broker rejected the request: #{e.message}\n", exit_status: rejection_status(e)))
        ensure
          client&.close
        end
      end

      def rejection_status(error)
        error.message.include?("restricted") ? 77 : (error.message.include?("destructive") ? 78 : 79)
      end

      def execute(request)
        raise "scoped GitHub credential expired" unless @expires_at > Time.current
        name, args = request.fetch("command"), Array(request.fetch("args")).map(&:to_s)
        raise "unsupported command" unless @commands.key?(name)
        validate!(name, args)
        started = Time.now.utc.iso8601
        stdout, stderr, status = Open3.capture3(command_environment(name), @commands.fetch(name), *args, chdir: request.fetch("cwd"))
        record(name, args, stdout, status, started)
        { stdout:, stderr:, exit_status: status.exitstatus }
      end

      def validate!(name, args)
        joined = args.join(" ")
        refs = repo_refs(args)
        raise "access is restricted to #{@repository}" if refs.any? { |candidate| !candidate.sub(/\.git\z/, "").casecmp?(@repository) }
        if name == "git"
          raise "this git command is unavailable in scoped break-glass mode" if args.first == "credential" || joined.match?(/(?:^|\s)-c\s+alias\./)
          if args.first == "push" && !@destructive
            raise "this destructive Git operation requires separately confirmed destructive authority"
          end
          return
        end
        raise "high-level gh commands are unavailable; only gh api is supported in scoped break-glass mode" unless args.first == "api"
        explicit = args.each_index.filter_map { |i| args[i + 1] if %w[-R --repo].include?(args[i]) }.compact
        raise "access is restricted to #{@repository}" if explicit.any? { |candidate| !candidate.casecmp?(@repository) }
        validate_api!(args)
        raise "this destructive GitHub operation requires separately confirmed destructive authority" if joined.match?(DESTRUCTIVE_GH) && !@destructive
      end

      def validate_api!(args)
        endpoint = args.drop(1).find { |arg| arg.start_with?("/", "repos/") }.to_s.delete_prefix("/")
        raise "GitHub API access is restricted to repos/#{@repository}" unless endpoint == "repos/#{@repository}" || endpoint.start_with?("repos/#{@repository}/")
      end

      def repo_refs(args) = args.filter_map { |arg| arg[%r{(?:github\.com[:/]|repos/)([^/\s]+/[^/\s]+)}, 1] }

      def command_environment(name)
        return @proxy.gh_environment.merge("GH_REPO" => @repository) if name == "gh"

        @proxy.git_environment.merge("GIT_TERMINAL_PROMPT" => "0")
      end

      def record(name, args, stdout, status, started)
        entry = { "category" => name == "git" ? (args.first == "push" ? "git_push" : "git_read_or_local") : "gh_#{args.first || 'unknown'}",
          "operation" => name == "gh" ? args.first(2) : args.first(1), "targets" => repo_refs(args), "started_at" => started,
          "finished_at" => Time.now.utc.iso8601, "result" => status.success? ? "succeeded" : "failed", "exit_status" => status.exitstatus,
          "provider_object_identifiers" => stdout.scan(%r{https://github\.com/[^\s]+|\b[0-9a-f]{40}\b}).uniq }
        @audit_mutex.synchronize { @audit_entries << entry }
      end

      def record_proxy_request(method:, path:, status:, body:, started_at:)
        return if %w[GET HEAD OPTIONS].include?(method)

        entry = {
          "category" => path.include?(".git/") ? "git_transport" : "gh_api",
          "operation" => [ method, path ], "targets" => [ @repository ],
          "started_at" => started_at, "finished_at" => Time.now.utc.iso8601,
          "result" => status.between?(200, 399) ? "succeeded" : "failed", "exit_status" => nil,
          "provider_object_identifiers" => body.to_s.scan(%r{https://github\.com/[^\s"']+|\b[0-9a-f]{40}\b}).uniq
        }
        @audit_mutex.synchronize { @audit_entries << entry }
      end
    end

    # Loopback TLS reverse proxy that adds the real credential only to
    # worker-owned outbound requests. Provider subprocesses receive a harmless
    # placeholder credential and a public CA certificate, never the grant.
    class CredentialProxy
      def initialize(dir:, token:, repository:, destructive:, on_request: nil)
        @dir, @token, @repository, @destructive = dir, token, repository, destructive
        @on_request = on_request
        @proxy_capability = SecureRandom.hex(32)
      end

      def start
        key, certificate = certificate_pair
        @certificate_path = File.join(@dir, "broker-ca.pem")
        File.write(@certificate_path, certificate.to_pem, mode: "w", perm: 0o644)
        tcp = TCPServer.new("127.0.0.1", 0)
        @port = tcp.addr[1]
        context = OpenSSL::SSL::SSLContext.new
        context.cert, context.key = certificate, key
        @server = OpenSSL::SSL::SSLServer.new(tcp, context)
        @thread = Thread.new { serve }
        self
      end

      def stop
        @server&.close
        @thread&.join(1)
      rescue IOError, Errno::EBADF
        nil
      ensure
        @token = nil
      end

      def gh_environment
        { "GH_HOST" => host, "GH_ENTERPRISE_TOKEN" => @proxy_capability, "SSL_CERT_FILE" => @certificate_path }
      end

      def git_environment
        {
          "GIT_CONFIG_COUNT" => "4",
          "GIT_CONFIG_KEY_0" => "url.https://#{host}/.insteadOf", "GIT_CONFIG_VALUE_0" => "https://github.com/",
          "GIT_CONFIG_KEY_1" => "url.https://#{host}/.insteadOf", "GIT_CONFIG_VALUE_1" => "git@github.com:",
          "GIT_CONFIG_KEY_2" => "http.https://#{host}/.sslCAInfo", "GIT_CONFIG_VALUE_2" => @certificate_path,
          "GIT_CONFIG_KEY_3" => "http.https://#{host}/.extraHeader", "GIT_CONFIG_VALUE_3" => "Authorization: Bearer #{@proxy_capability}"
        }
      end

      private

      def host = "127.0.0.1:#{@port}"

      def serve
        loop do
          client = @server.accept
          handle(client)
        rescue IOError, Errno::EBADF
          break
        rescue StandardError
          client&.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") rescue nil
        ensure
          client&.close
        end
      end

      def handle(client)
        started_at = Time.now.utc.iso8601
        request_line = client.gets("\r\n")&.strip.to_s
        method, target, = request_line.split(" ", 3)
        headers = read_headers(client)
        supplied_capability = headers["authorization"].to_s.sub(/\A(?:Bearer|token)\s+/i, "")
        raise "proxy authorization is invalid" unless ActiveSupport::SecurityUtils.secure_compare(supplied_capability, @proxy_capability)
        body = request_body(client, headers)
        upstream, path, authorization = upstream_for(target)
        raise "destructive proxy request requires authority" if destructive_request?(method, path, body) && !@destructive
        response = Faraday.public_send(method.downcase, "#{upstream}#{path}", body) do |request|
          headers.each { |key, value| request.headers[key] = value unless %w[host authorization connection content-length].include?(key) }
          request.headers["Authorization"] = authorization
          request.headers["User-Agent"] = GithubClient::USER_AGENT
        end
        response_body = response.body.to_s.b
        @on_request&.call(method:, path:, status: response.status, body: response_body, started_at:)
        client.write("HTTP/1.1 #{response.status} Proxy Response\r\n")
        response.headers.each { |key, value| client.write("#{key}: #{value}\r\n") unless %w[transfer-encoding connection content-length].include?(key.downcase) }
        client.write("Content-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n")
        client.write(response_body)
      end

      def request_body(client, headers)
        return client.read(Integer(headers["content-length"])) if headers["content-length"]
        return "" unless headers["transfer-encoding"].to_s.downcase.include?("chunked")

        body = +"".b
        loop do
          size = Integer(client.gets("\r\n").to_s.strip, 16)
          break if size.zero?
          body << client.read(size)
          client.read(2)
        end
        while (line = client.gets("\r\n")) && line != "\r\n"
          nil
        end
        body
      end

      def read_headers(client)
        {}.tap do |headers|
          while (line = client.gets("\r\n")) && line != "\r\n"
            key, value = line.split(":", 2)
            headers[key.downcase] = value.to_s.strip
          end
        end
      end

      def upstream_for(target)
        uri = URI.parse(target)
        path = uri.path.to_s
        path = "/#{path}" unless path.start_with?("/")
        path = "#{path}?#{uri.query}" if uri.query
        api_path = path.delete_prefix("/api/v3")
        if api_path == "/repos/#{@repository}" || api_path.start_with?("/repos/#{@repository}/")
          [ "https://api.github.com", api_path, "Bearer #{@token}" ]
        elsif path.start_with?("/#{@repository}.git/") || path == "/#{@repository}.git"
          basic = Base64.strict_encode64("x-access-token:#{@token}")
          [ "https://github.com", path, "Basic #{basic}" ]
        else
          raise "proxy request is restricted to #{@repository}"
        end
      end

      def destructive_request?(method, path, body)
        return true if %w[DELETE PUT].include?(method)
        return true if path.include?("/git-receive-pack")
        return true if method == "POST" && path.match?(%r{/repos/#{Regexp.escape(@repository)}/issues/\d+/lock\z})
        if method == "PATCH" && path == "/repos/#{@repository}"
          return ActiveModel::Type::Boolean.new.cast(parse_body(body)["archived"])
        end
        return false unless method == "PATCH" && path.match?(%r{/repos/#{Regexp.escape(@repository)}/(?:pulls|issues)/\d+\z})

        values = parse_body(body)
        values["state"].to_s.casecmp?("closed")
      end

      def parse_body(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        URI.decode_www_form(body.to_s).to_h
      end

      def certificate_pair
        key = OpenSSL::PKey::RSA.new(2048)
        certificate = OpenSSL::X509::Certificate.new
        certificate.version = 2
        certificate.serial = SecureRandom.random_number(2**63)
        certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
        certificate.public_key = key.public_key
        certificate.not_before = Time.now - 60
        certificate.not_after = Time.now + 2.hours
        extensions = OpenSSL::X509::ExtensionFactory.new
        extensions.subject_certificate = extensions.issuer_certificate = certificate
        certificate.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
        certificate.add_extension(extensions.create_extension("subjectAltName", "IP:127.0.0.1"))
        certificate.sign(key, OpenSSL::Digest::SHA256.new)
        [ key, certificate ]
      end
    end
  end
end
