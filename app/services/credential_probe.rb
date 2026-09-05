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
    "github_token"       => :probe_github
  }.freeze
  @registered_probe_handlers = {}
  @registered_secret_extractors = []

  # Both return the teardown that removes exactly this registration again, so
  # a disabled plugin stops contributing probes rather than leaving a handler
  # pointing at code that may no longer be loaded (see Syrus::Installer).
  # A handler may also expose `.key(key:) => Result` for the paste-and-test
  # flow, where the operator is validating a key they have not saved yet.
  # Optional: a credential with no such flow simply does not define it, and
  # `key_probe_for` answers nil.
  def self.key_probe_for(credential)
    handler = probe_handler_for(credential)
    return nil unless handler.respond_to?(:key)

    handler
  end

  def self.register_probe(credential, handler)
    key = credential.to_s
    previous = @registered_probe_handlers[key]
    @registered_probe_handlers[key] = handler

    -> { previous ? @registered_probe_handlers[key] = previous : @registered_probe_handlers.delete(key) }
  end

  def self.register_secret_extractor(extractor)
    return -> { } if @registered_secret_extractors.include?(extractor)

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

  private

  attr_reader :user, :credential

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
