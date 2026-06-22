require "base64"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "socket"
require "uri"

# Drives the Codex CLI ChatGPT OAuth flow from Syrus. Codex's first-party
# browser login uses a localhost callback server; Syrus reuses the same public
# client, PKCE, and token endpoint, then either captures the localhost callback
# or lets the operator paste the returned callback URL as a fallback.
class CodexOauth
  Error = Class.new(StandardError)

  CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann".freeze
  ISSUER = "https://auth.openai.com".freeze
  AUTHORIZE_URL = "#{ISSUER}/oauth/authorize".freeze
  TOKEN_URL = "#{ISSUER}/oauth/token".freeze
  # Kept in sync with the Codex CLI Hydra redirect URI allow-list.
  PASTE_REDIRECT_URI = "http://localhost:1455/auth/callback".freeze
  CALLBACK_HOST = "localhost".freeze
  CALLBACK_PORT = 1455
  CALLBACK_PATH = "/auth/callback".freeze
  CALLBACK_TIMEOUT = 5.minutes
  SCOPE = "openid profile email offline_access api.connectors.read api.connectors.invoke".freeze

  Begin = Data.define(:authorize_url, :verifier, :state, :redirect_uri)

  def self.begin(redirect_uri:)
    verifier = SecureRandom.urlsafe_base64(64)
    state = SecureRandom.urlsafe_base64(32)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    query = {
      response_type: "code",
      client_id: CLIENT_ID,
      redirect_uri: redirect_uri,
      scope: SCOPE,
      code_challenge: challenge,
      code_challenge_method: "S256",
      id_token_add_organizations: "true",
      codex_cli_simplified_flow: "true",
      state: state,
      originator: "codex_cli_rs"
    }

    Begin.new(
      authorize_url: "#{AUTHORIZE_URL}?#{URI.encode_www_form(query)}",
      verifier: verifier,
      state: state,
      redirect_uri: redirect_uri
    )
  end

  def self.exchange(code:, verifier:, state:, redirect_uri:)
    raw_code, embedded_state = extract_code_and_state(code)
    raise Error, "Missing authorization code." if raw_code.blank?

    if embedded_state.present? && embedded_state != state
      raise Error, "Authorization state did not match. Start a new ChatGPT authorization."
    end

    response = post_form(
      TOKEN_URL,
      grant_type: "authorization_code",
      code: raw_code,
      redirect_uri: redirect_uri,
      client_id: CLIENT_ID,
      code_verifier: verifier
    )

    tokens = %w[ id_token access_token refresh_token ].to_h do |key|
      value = response[key].to_s
      raise Error, "OpenAI did not return #{key}." if value.blank?

      [ key, value ]
    end

    JSON.pretty_generate(
      "auth_mode" => "chatgpt",
      "tokens" => tokens,
      "last_refresh" => Time.current.utc.iso8601
    ) + "\n"
  end

  def self.start_callback_listener(user:, timeout: CALLBACK_TIMEOUT)
    server = TCPServer.new(CALLBACK_HOST, CALLBACK_PORT)
    thread = Thread.new do
      Thread.current.abort_on_exception = false
      Thread.current.report_on_exception = false

      Rails.application.executor.wrap do
        capture_callback(server: server, user: user, timeout: timeout)
      end
    ensure
      server&.close unless server&.closed?
    end
    thread.name = "codex-oauth-callback-listener" if thread.respond_to?(:name=)
    true
  rescue Errno::EADDRINUSE, Errno::EACCES => e
    Rails.logger.warn("Codex OAuth localhost callback listener unavailable on #{CALLBACK_HOST}:#{CALLBACK_PORT}: #{e.class}: #{e.message}")
    false
  end

  def self.capture_callback(server:, user:, timeout:)
    ready = IO.select([ server ], nil, nil, timeout)
    return unless ready

    socket = server.accept
    request_line = socket.gets.to_s
    method, target = request_line.split(/\s+/, 3)
    uri = URI.parse(target.to_s)

    if method == "GET" && uri.path == CALLBACK_PATH
      params = Rack::Utils.parse_query(uri.query)
      callback_url = "#{PASTE_REDIRECT_URI}?#{URI.encode_www_form(params)}"
      write_callback_response(socket, status: "200 OK", body: callback_success_html)
      AppEvents.broadcast(
        user: user,
        type: "codex_oauth.callback",
        resource: "credential",
        payload: { "code" => callback_url }
      )
    else
      write_callback_response(socket, status: "404 Not Found", body: callback_not_found_html)
    end
  rescue URI::InvalidURIError => e
    Rails.logger.warn("Codex OAuth callback listener received an invalid callback request: #{e.message}")
  rescue IOError, SystemCallError => e
    Rails.logger.warn("Codex OAuth callback listener failed: #{e.class}: #{e.message}")
  ensure
    socket&.close unless socket&.closed?
  end
  private_class_method :capture_callback

  def self.write_callback_response(socket, status:, body:)
    response = [
      "HTTP/1.1 #{status}",
      "Content-Type: text/html; charset=utf-8",
      "Content-Length: #{body.bytesize}",
      "Connection: close",
      "",
      body
    ].join("\r\n")
    socket.write(response)
  end
  private_class_method :write_callback_response

  def self.callback_success_html
    <<~HTML
      <!doctype html>
      <html>
        <head><title>Authorization received</title></head>
        <body>
          <h1>Authorization received</h1>
          <p>You can close this tab and return to Syrus.</p>
        </body>
      </html>
    HTML
  end
  private_class_method :callback_success_html

  def self.callback_not_found_html
    <<~HTML
      <!doctype html>
      <html>
        <head><title>Not found</title></head>
        <body>
          <h1>Not found</h1>
        </body>
      </html>
    HTML
  end
  private_class_method :callback_not_found_html

  def self.extract_code_and_state(code)
    raw_code, embedded_state = code.to_s.strip.split("#", 2)
    value = raw_code.to_s.strip
    return [ value, embedded_state ] unless value.include?("code=")

    uri = URI.parse(value)
    params = Rack::Utils.parse_query(uri.query)
    [ params["code"].to_s.strip, params["state"].presence || embedded_state ]
  rescue URI::InvalidURIError
    [ value, embedded_state ]
  end
  private_class_method :extract_code_and_state

  def self.post_form(url, body)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 15
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/x-www-form-urlencoded"
    request["Accept"] = "application/json"
    request.body = URI.encode_www_form(body)

    response = http.request(request)
    parsed = parse_body(response.body)

    unless response.is_a?(Net::HTTPSuccess)
      message = parsed["error_description"].presence || parsed.dig("error", "message").presence ||
                parsed["error"].presence || "OpenAI rejected the authorization (HTTP #{response.code})."
      raise Error, message
    end

    parsed
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, "Timed out talking to OpenAI's OAuth server. Try again."
  rescue SocketError, SystemCallError
    raise Error, "Could not reach OpenAI's OAuth server."
  end
  private_class_method :post_form

  def self.parse_body(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError
    {}
  end
  private_class_method :parse_body
end
