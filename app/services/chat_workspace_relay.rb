require "socket"
require "uri"
require "json"

# Lightweight per-worker HTTP relay that serves coding workspace file/diff reads
# from the worker pod's local filesystem to the web pod over the pod network.
#
# Mirrors the terminal relay pattern (TerminalRelay + TerminalSession): the
# worker records its host:port in the DB (chat_sessions.coding_relay_address),
# the web pod proxies the three coding API endpoints to it, and request auth
# is a per-session bearer token (chat_sessions.coding_relay_token).
#
# Three routes:
#   GET /workspace/files?session_id=N
#   GET /workspace/file?session_id=N&path=<rel_path>
#   GET /workspace/diff?session_id=N&mode=<cumulative|turn>
class ChatWorkspaceRelay
  DEFAULT_PORT = 9283

  HTTP_STATUS_REASONS = {
    200 => "OK",
    400 => "Bad Request",
    401 => "Unauthorized",
    404 => "Not Found",
    422 => "Unprocessable Entity",
    500 => "Internal Server Error"
  }.freeze

  MUTEX = Mutex.new
  private_constant :MUTEX

  class << self
    # Starts the relay server in a background thread. Idempotent: a second call
    # while the server is running is a no-op.
    def start!
      MUTEX.synchronize do
        return if @server

        host = ENV["SYRUS_TERMINAL_HOST"].presence || "127.0.0.1"
        port = ENV["SYRUS_WORKSPACE_RELAY_PORT"].to_i.nonzero? || DEFAULT_PORT

        @server = TCPServer.new(host, port)
        @relay_address = "#{host}:#{port}"

        @server_thread = Thread.new do
          loop do
            client = @server.accept
            Thread.new(client) { |c| handle_connection(c) }
          rescue IOError, Errno::EBADF
            break
          rescue StandardError => e
            Rails.logger.error("ChatWorkspaceRelay: accept error: #{e.class}: #{e.message}")
          end
        end
      end
    end

    def stop!
      MUTEX.synchronize do
        @server&.close
        @server_thread&.join(5)
        @server = nil
        @server_thread = nil
        @relay_address = nil
      end
    end

    # Returns "host:port" when the server is running, nil otherwise.
    # Writable so tests can inject a stub address without starting a server.
    def relay_address
      @relay_address
    end

    def relay_address=(addr)
      @relay_address = addr
    end

    private

    def handle_connection(client)
      request_line = client.gets
      return unless request_line

      _method, raw_path, _version = request_line.chomp.split(" ", 3)

      headers = {}
      while (line = client.gets) && line.chomp != ""
        name, value = line.chomp.split(": ", 2)
        headers[name.downcase] = value if name && value
      end

      uri = URI.parse(raw_path)
      params = URI.decode_www_form(uri.query || "").to_h

      case uri.path
      when "/workspace/files" then handle_files(client, headers, params)
      when "/workspace/file"  then handle_file(client, headers, params)
      when "/workspace/diff"  then handle_diff(client, headers, params)
      else send_response(client, 404)
      end
    rescue StandardError => e
      Rails.logger.error("ChatWorkspaceRelay: request error: #{e.class}: #{e.message}")
    ensure
      client.close rescue nil
    end

    def handle_files(client, headers, params)
      session, error_status = authenticate(headers, params)
      return send_response(client, error_status) unless session

      repo = session.repository
      return send_response(client, 422) unless repo

      result = ChatWorkspace.file_tree(session, repo)
      return send_response(client, 404) unless result

      send_response(client, 200, result)
    rescue StandardError => e
      Rails.logger.error("ChatWorkspaceRelay /workspace/files: #{e.class}: #{e.message}")
      send_response(client, 500)
    end

    def handle_file(client, headers, params)
      session, error_status = authenticate(headers, params)
      return send_response(client, error_status) unless session

      repo = session.repository
      return send_response(client, 422) unless repo

      path_param = params["path"].to_s.strip
      return send_response(client, 422) if path_param.blank?

      result = ChatWorkspace.file_content(session, repo, path_param)
      return send_response(client, 404) unless result

      send_response(client, 200, result.merge(path: path_param))
    rescue StandardError => e
      Rails.logger.error("ChatWorkspaceRelay /workspace/file: #{e.class}: #{e.message}")
      send_response(client, 500)
    end

    def handle_diff(client, headers, params)
      session, error_status = authenticate(headers, params)
      return send_response(client, error_status) unless session

      repo = session.repository
      return send_response(client, 422) unless repo

      mode = params["mode"].to_s == "turn" ? :turn : :cumulative
      diff = ChatWorkspace.coding_diff(session, repo, mode: mode)

      send_response(client, 200, {
        diff: diff,
        mode: mode.to_s,
        checkout_branch: session.coding_checkout_branch
      })
    rescue StandardError => e
      Rails.logger.error("ChatWorkspaceRelay /workspace/diff: #{e.class}: #{e.message}")
      send_response(client, 500)
    end

    # Returns [session, nil] on success, [nil, http_status_integer] on failure.
    def authenticate(headers, params)
      session_id = params["session_id"].to_s
      return [nil, 400] if session_id.blank?

      session = ChatSession.find_by(id: session_id)
      return [nil, 404] unless session
      return [nil, 401] if session.coding_relay_token.blank?

      provided = headers["authorization"].to_s.delete_prefix("Bearer ").strip
      unless ActiveSupport::SecurityUtils.secure_compare(provided, session.coding_relay_token)
        return [nil, 401]
      end

      [session, nil]
    end

    def send_response(client, status, data = nil)
      reason = HTTP_STATUS_REASONS[status] || "Error"
      body = (data || { error: reason }).to_json
      client.print(
        "HTTP/1.1 #{status} #{reason}\r\n" \
        "Content-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n" \
        "\r\n" \
        "#{body}"
      )
    end
  end
end
