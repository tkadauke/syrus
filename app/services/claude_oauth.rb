require "base64"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "uri"

# Drives the Claude Code subscription OAuth flow (the same one `claude
# setup-token` uses) so an operator can mint a long-lived
# CLAUDE_CODE_OAUTH_TOKEN from inside Syrus instead of pasting one from a
# terminal.
#
# The constants below are Claude Code's first-party public OAuth client. They
# are not officially published for third-party reuse, so treat them as
# reverse-engineered and subject to change. PKCE (S256) is mandatory; there is
# no client secret.
#
# The client only whitelists the provider-hosted callback below (the one
# `claude setup-token` uses), so Syrus uses the copy-and-paste flow: open the
# authorize URL, the provider shows a `code#state` string, the operator pastes
# it back, and `exchange` completes it. (A loopback/same-host redirect to
# Syrus is rejected by this client with "Redirect URI is not supported".)
class ClaudeOauth
  Error = Class.new(StandardError)

  CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e".freeze
  AUTHORIZE_URL = "https://claude.ai/oauth/authorize".freeze
  TOKEN_URL = "https://console.anthropic.com/v1/oauth/token".freeze
  # Provider-hosted callback that displays the code for the paste flow.
  PASTE_REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback".freeze
  SCOPE = "org:create_api_key user:profile user:inference".freeze

  Begin = Data.define(:authorize_url, :verifier, :state, :redirect_uri)

  # Generate PKCE material and the authorize URL for a given redirect_uri.
  # Persist the returned verifier + state (e.g. in the session) until the
  # callback so `exchange` can complete.
  def self.begin(redirect_uri:)
    verifier = SecureRandom.urlsafe_base64(32)
    state = SecureRandom.urlsafe_base64(32)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    query = {
      code: "true",
      client_id: CLIENT_ID,
      response_type: "code",
      redirect_uri: redirect_uri,
      scope: SCOPE,
      code_challenge: challenge,
      code_challenge_method: "S256",
      state: state
    }
    url = "#{AUTHORIZE_URL}?#{URI.encode_www_form(query)}"

    Begin.new(authorize_url: url, verifier: verifier, state: state, redirect_uri: redirect_uri)
  end

  # Returns true when the value looks like a long-lived Claude Code OAuth token
  # (sk-ant-* prefix) rather than a one-time authorization code. Used by the
  # exchange endpoint to short-circuit when a user pastes a token directly
  # instead of the code from the provider page.
  def self.looks_like_token?(value)
    value.to_s.strip.start_with?("sk-ant-")
  end

  # Exchange an authorization code for a long-lived token. `code` may be the
  # raw query-string value or the `code#state` form from the paste flow.
  # Returns the access token string. Raises ClaudeOauth::Error on any failure.
  def self.exchange(code:, verifier:, state:, redirect_uri:)
    raw_code, embedded_state = code.to_s.split("#", 2)
    raw_code = raw_code.to_s.strip
    raise Error, "Missing authorization code." if raw_code.blank?

    effective_state = embedded_state.presence || state

    body = {
      grant_type: "authorization_code",
      client_id: CLIENT_ID,
      code: raw_code,
      redirect_uri: redirect_uri,
      code_verifier: verifier,
      state: effective_state
    }

    response = post_json(TOKEN_URL, body)
    token = response["access_token"].to_s
    raise Error, "Claude did not return an access token." if token.blank?

    token
  end

  def self.post_json(url, body)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 15
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request.body = JSON.generate(body)

    response = http.request(request)
    parsed = parse_body(response.body)

    unless response.is_a?(Net::HTTPSuccess)
      message = parsed["error_description"].presence || parsed["error"].presence ||
                "Claude rejected the authorization (HTTP #{response.code})."
      raise Error, message
    end

    parsed
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, "Timed out talking to Claude's OAuth server. Try again."
  rescue SocketError, SystemCallError
    raise Error, "Could not reach Claude's OAuth server."
  end
  private_class_method :post_json

  def self.parse_body(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError
    {}
  end
  private_class_method :parse_body
end
