require "base64"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "uri"

# Drives the Codex CLI ChatGPT OAuth flow from Syrus. Codex's first-party
# browser login uses a localhost callback server; Syrus reuses the same public
# client, PKCE, and token endpoint, then asks the operator to paste the
# returned code instead of running a callback route in this app.
class CodexOauth
  Error = Class.new(StandardError)

  CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann".freeze
  ISSUER = "https://auth.openai.com".freeze
  AUTHORIZE_URL = "#{ISSUER}/oauth/authorize".freeze
  TOKEN_URL = "#{ISSUER}/oauth/token".freeze
  # Kept in sync with the Codex CLI Hydra redirect URI allow-list.
  PASTE_REDIRECT_URI = "http://localhost:1455/auth/callback".freeze
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
