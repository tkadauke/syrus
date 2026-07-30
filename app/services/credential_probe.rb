require "fileutils"
require "json"
require "tmpdir"

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
    "claude_oauth_token" => :probe_claude,
    "codex_api_key"      => :probe_codex,
    "codex_auth_json"    => :probe_codex,
    "gemini_api_key"     => :probe_gemini
  }.freeze

  def call
    probe_method = CREDENTIAL_PROBE_METHODS[credential]
    raise ArgumentError, "Unknown credential: #{credential}" unless probe_method

    send(probe_method)
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

  # Probe whether `claude --print` already works on this machine using the
  # CLI's own stored login (no Syrus token injected). Lets the setup wizard
  # detect a working bare-metal subscription before asking for a token.
  def self.claude_cli_ready(user: nil)
    new(user: user, credential: "claude_oauth_token").send(:probe_claude, ambient: true)
  end

  def probe_claude(ambient: false)
    return missing("Claude OAuth token is not configured.") if !ambient && user&.claude_oauth_token.blank?

    token = ambient ? nil : user.claude_oauth_token
    Dir.mktmpdir("syrus-claude-probe-") do |workspace|
      output = +""
      result = ProcessRunner.new(
        env: ProcessRunner.forwarded_env(
          AgentInvocation::ENV_FORWARD,
          extra: token ? { "CLAUDE_CODE_OAUTH_TOKEN" => token } : {}
        ),
        command: [
          "claude", "--print",
          "--output-format", "stream-json",
          "--verbose",
          "--max-turns", "1",
          "Reply with OK."
        ],
        chdir: workspace,
        timeout: TIMEOUT_SECONDS,
        silent_timeout: 15,
        kind: "agent",
        on_output_chunk: ->(chunk) { append_output(output, chunk) }
      ).run

      if result.success?
        return success(credential, ambient ? "Claude already works on this machine — no token needed." : "Claude OAuth token is valid.")
      end

      message = ambient ? "Claude is not authenticated on this machine yet." : "Claude probe failed: #{probe_failure_reason(result, output)}"
      failure(message)
    end
  rescue Errno::ENOENT
    failure("Claude CLI is not installed or not on PATH.")
  end

  CODEX_CREDENTIAL_SPECS = {
    "codex_api_key" => {
      credential_attr: :codex_api_key,
      missing_message: "Codex API key is not configured.",
      required_mode: "api_key",
      wrong_mode_message: "Codex is set to ChatGPT auth.json mode."
    },
    "codex_auth_json" => {
      credential_attr: :codex_auth_json,
      missing_message: "Codex ChatGPT auth.json is not configured.",
      required_mode: "chatgpt_login",
      wrong_mode_message: "Codex is set to API key mode."
    }
  }.freeze

  def probe_codex
    spec = CODEX_CREDENTIAL_SPECS.fetch(credential)
    return missing(spec[:missing_message]) if user.send(spec[:credential_attr]).blank?
    return wrong_mode(spec[:wrong_mode_message]) unless user.codex_auth_mode == spec[:required_mode]

    Dir.mktmpdir("syrus-codex-probe-") do |workspace|
      codex_home = File.join(workspace, ".codex")
      FileUtils.mkdir_p(codex_home)
      CodexAuth.with_refresh_lock(user: user) do
        codex_auth = CodexAuth.new(user: user, codex_home: codex_home)
        auth = codex_auth.prepare!
        File.write(File.join(codex_home, "config.toml"), codex_config)

        output = +""
        result = ProcessRunner.new(
          env: ProcessRunner.forwarded_env(
            AgentInvocation::ENV_FORWARD,
            extra: {
              "CODEX_HOME" => codex_home,
              "CODEX_API_KEY" => auth.api_key.presence
            }
          ),
          command: [
            "codex", "exec",
            "--cd", workspace,
            "--dangerously-bypass-approvals-and-sandbox",
            "--json",
            "Reply with OK."
          ],
          chdir: workspace,
          timeout: TIMEOUT_SECONDS,
          silent_timeout: 15,
          kind: "agent",
          on_output_chunk: ->(chunk) { append_output(output, chunk) }
        ).run

        if result.success?
          codex_auth.persist_updated_auth_json
          details = {}
          if user.codex_auth_mode == "chatgpt_login"
            usage = CodexUsageProbe.refresh_for(user: user, force: true)
            details[:codex_usage] = usage.snapshot if usage.snapshot.present?
          end
          return Result.new(credential: credential, ok: true, message: "Codex credentials are valid.", details: details)
        end

        failure("Codex probe failed: #{probe_failure_reason(result, output)}")
      end
    end
  rescue CodexAuth::Error => e
    failure(e.message)
  rescue Errno::ENOENT
    failure("Codex CLI is not installed or not on PATH.")
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
      user.github_token,
      user.claude_oauth_token,
      user.codex_api_key
    ].compact_blank.each do |secret|
      text = text.gsub(secret, REDACTED)
    end

    if user.codex_auth_json.present?
      begin
        JSON.parse(user.codex_auth_json).dig("tokens").to_h.values.compact_blank.each do |secret|
          text = text.gsub(secret, REDACTED)
        end
      rescue JSON::ParserError
        nil
      end
    end

    text.lines.map(&:strip).reject(&:blank?).last(3).join(" ").truncate(500)
  end

  def safe_error(error)
    sanitize(error.message)
  end

  def scopes_from(headers, key = "x-oauth-scopes")
    headers.fetch(key, "").to_s.split(",").map(&:strip).compact_blank
  end

  def codex_config
    [
      'cli_auth_credentials_store = "file"',
      'approval_policy = "never"',
      "model = #{JSON.generate(CodexInvocation::DEFAULT_MODEL)}"
    ].join("\n") + "\n"
  end
end
