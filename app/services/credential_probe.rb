class CredentialProbe
  Result = Data.define(:credential, :ok, :message, :details) do
    def as_json(*)
      {
        credential: credential,
        ok: ok,
        message: message,
        details: details
      }
    end
  end

  TIMEOUT_SECONDS = 30
  MAX_OUTPUT_BYTES = 4_000
  REDACTED = "[redacted]".freeze

  def self.call(user:, credential:)
    new(user: user, credential: credential).call
  end

  def initialize(user:, credential:)
    @user = user
    @credential = credential.to_s
  end

  # Validate a GitHub token that has NOT been saved yet (the onboarding
  # paste-and-test flow). Returns a Result whose details carry the resolved
  # login, the token's OAuth scopes, and any `required_scopes` it is missing
  # so the UI can distinguish "invalid" from "valid but under-scoped".
  def self.github_token(token:, required_scopes: [])
    token = token.to_s
    return Result.new(credential: "github_token", ok: false, message: "Paste a token to test it.", details: {}) if token.blank?

    client = Octokit::Client.new(
      access_token: token,
      user_agent: GithubClient::USER_AGENT,
      connection_options: GithubClient.connection_options
    )
    github_user = client.user
    headers = client.last_response&.headers || {}
    scopes = headers.fetch("x-oauth-scopes", "").to_s.split(",").map(&:strip).compact_blank
    missing = required_scopes.map(&:to_s) - scopes

    if missing.any?
      label = missing.size == 1 ? "scope" : "scopes"
      Result.new(
        credential: "github_token",
        ok: false,
        message: "Token authenticated as #{github_user.login}, but it is missing the #{missing.join(" and ")} #{label}. " \
                 "Regenerate a classic token with repo and workflow enabled.",
        details: { login: github_user.login, scopes: scopes, missing_scopes: missing }
      )
    else
      Result.new(
        credential: "github_token",
        ok: true,
        message: "Token is valid for #{github_user.login}.",
        details: { login: github_user.login, scopes: scopes, missing_scopes: [] }
      )
    end
  rescue Octokit::Unauthorized
    Result.new(credential: "github_token", ok: false, message: "GitHub rejected this token. Check that you copied the whole value.", details: {})
  rescue Octokit::Forbidden
    # A fine-grained token can authenticate but forbid the user lookup; classic
    # tokens with the documented scopes do not hit this.
    Result.new(credential: "github_token", ok: false, message: "GitHub accepted the token but refused to read your account. Use a classic token with the repo and workflow scopes.", details: {})
  rescue Octokit::Error
    Result.new(credential: "github_token", ok: false, message: "Could not reach GitHub to verify the token. Try again in a moment.", details: {})
  end

  CREDENTIAL_PROBE_METHODS = {
    "github_token"       => :probe_github,
    "gemini_api_key"     => :probe_gemini
  }.freeze
  @registered_probe_handlers = {}
  @registered_secret_extractors = []

  # Both return the teardown that removes exactly this registration again, so
  # a disabled plugin stops contributing probes rather than leaving a handler
  # pointing at code that may no longer be loaded (see Syrus::Installer).
  def self.register_probe(credential, handler)
    key = credential.to_s
    previous = @registered_probe_handlers[key]
    @registered_probe_handlers[key] = handler

    -> { previous ? @registered_probe_handlers[key] = previous : @registered_probe_handlers.delete(key) }
  end

  def self.register_secret_extractor(extractor)
    return -> {} if @registered_secret_extractors.include?(extractor)

    @registered_secret_extractors << extractor
    -> { @registered_secret_extractors.delete(extractor) }
  end

  def self.probe_handler_for(credential)
    Syrus::Installer.sync!
    CREDENTIAL_PROBE_METHODS[credential.to_s] || @registered_probe_handlers[credential.to_s]
  end

  def call
    probe_handler = self.class.probe_handler_for(credential)
    raise ArgumentError, "Unknown credential: #{credential}" unless probe_handler

    probe_handler.is_a?(Symbol) ? send(probe_handler) : probe_handler.call(self)
  end

  # Validate a pasted-but-unsaved Gemini API key (the setup sheet's
  # paste-and-test flow). models.list is free and requires a working key;
  # the details carry whether a video-capable flash model is actually
  # available to this key's project — the whole point of configuring Gemini.
  def self.gemini_key(key:)
    key = key.to_s.strip
    if key.blank?
      return Result.new(credential: "gemini_api_key", ok: false, message: "Paste a key to test it.", details: {})
    end

    models = gemini_client_factory.call(api_key: key).list_models
    video_model = preferred_gemini_model(models)
    if video_model
      Result.new(
        credential: "gemini_api_key",
        ok: true,
        message: "Gemini key is valid — #{video_model} is available for video analysis.",
        details: { model: video_model, models_available: models.size }
      )
    else
      Result.new(
        credential: "gemini_api_key",
        ok: false,
        message: "The key works, but no video-capable Gemini flash model is available to this project.",
        details: { models_available: models.size }
      )
    end
  rescue Gemini::Client::AuthError
    Result.new(credential: "gemini_api_key", ok: false,
               message: "Google rejected this key. Check that you copied the whole value from aistudio.google.com/apikey.", details: {})
  rescue Gemini::Client::RateLimited
    Result.new(credential: "gemini_api_key", ok: false,
               message: "The key looks throttled right now (free-tier quota). Try again in a minute.", details: {})
  rescue Gemini::Client::Error, SocketError, Timeout::Error, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError
    Result.new(credential: "gemini_api_key", ok: false,
               message: "Could not reach Google to verify the key. Try again in a moment.", details: {})
  end

  # Delegates to Gemini::Client::VIDEO_MODELS — the SAME list the analysis
  # job resolves against (resolve_video_model!), so a key that validates
  # green against a fallback model also analyzes with that model.
  def self.preferred_gemini_model(models)
    Gemini::Client::VIDEO_MODELS.find { |candidate| models.any? { |name| name.start_with?(candidate) } }
  end

  # Test seam: specs swap the factory instead of stubbing HTTP.
  class << self
    attr_writer :gemini_client_factory

    def gemini_client_factory
      @gemini_client_factory ||= ->(api_key:) { Gemini::Client.new(api_key: api_key) }
    end
  end

  private

  attr_reader :user, :credential

  # Saved-credential test (the /credentials "Test" button) — same probe as
  # the paste-and-test path, against the stored key.
  def probe_gemini
    return missing("Gemini API key is not configured.") if user.gemini_api_key.blank?

    self.class.gemini_key(key: user.gemini_api_key)
  end

  def probe_github
    return missing("GitHub token is not configured.") if user.github_token.blank?

    client = Octokit::Client.new(
      access_token: user.github_token,
      user_agent: GithubClient::USER_AGENT,
      connection_options: GithubClient.connection_options
    )
    github_user = client.user
    headers = client.last_response&.headers || {}
    scopes = scopes_from(headers)

    Result.new(
      credential: credential,
      ok: true,
      message: "GitHub token is valid for #{github_user.login}.",
      details: {
        login: github_user.login,
        scopes: scopes,
        accepted_scopes: scopes_from(headers, "x-accepted-oauth-scopes")
      }
    )
  rescue Octokit::Unauthorized
    failure("GitHub rejected this token.")
  rescue Octokit::Forbidden => e
    failure("GitHub accepted the token but refused the probe: #{safe_error(e)}")
  rescue Octokit::Error => e
    failure("GitHub probe failed: #{safe_error(e)}")
  end

  def self.claude_cli_ready(user: nil)
    probe = new(user: user, credential: "claude_oauth_token")
    handler = probe_handler_for("claude_oauth_token")
    raise ArgumentError, "Unknown credential: claude_oauth_token" unless handler
    raise ArgumentError, "Credential probe does not support ambient CLI readiness: claude_oauth_token" unless handler.respond_to?(:cli_ready)

    handler.cli_ready(probe)
  end

  def success(credential, message)
    Result.new(credential: credential, ok: true, message: message, details: {})
  end

  def missing(message)
    Result.new(credential: credential, ok: false, message: message, details: {})
  end

  def wrong_mode(message)
    Result.new(credential: credential, ok: false, message: message, details: {})
  end

  def failure(message)
    Result.new(credential: credential, ok: false, message: message, details: {})
  end

  def append_output(output, chunk)
    output << chunk.to_s
    output.slice!(0, output.bytesize - MAX_OUTPUT_BYTES) if output.bytesize > MAX_OUTPUT_BYTES
  end

  def probe_failure_reason(result, output)
    return "timed out." if result.timed_out?
    return "stopped after no output." if result.silent_timed_out?
    return "process exited before completion." if result.aliveness_failed?

    sanitized = sanitize(output).presence
    sanitized || "process exited with status #{result.exit_status || "unknown"}."
  end

  def sanitize(value)
    text = value.to_s
    [
      user.github_token
    ].concat(registered_secrets).compact_blank.each do |secret|
      text = text.gsub(secret, REDACTED)
    end

    text.lines.map(&:strip).reject(&:blank?).last(3).join(" ").truncate(500)
  end

  def safe_error(error)
    sanitize(error.message)
  end

  def scopes_from(headers, key = "x-oauth-scopes")
    headers.fetch(key, "").to_s.split(",").map(&:strip).compact_blank
  end

  def registered_secrets
    Syrus::Installer.sync!
    self.class.instance_variable_get(:@registered_secret_extractors).flat_map { |extractor| Array(extractor.call(user)) }
  end
end
