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

  def call
    case credential
    when "github_token"
      probe_github
    when "claude_oauth_token"
      probe_claude
    when "codex_api_key", "codex_auth_json"
      probe_codex
    else
      raise ArgumentError, "Unknown credential: #{credential}"
    end
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

  def probe_claude
    return missing("Claude OAuth token is not configured.") if user.claude_oauth_token.blank?

    Dir.mktmpdir("syrus-claude-probe-") do |workspace|
      output = +""
      result = ProcessRunner.new(
        env: ProcessRunner.forwarded_env(
          AgentInvocation::ENV_FORWARD,
          extra: { "CLAUDE_CODE_OAUTH_TOKEN" => user.claude_oauth_token }
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

      return success(credential, "Claude OAuth token is valid.") if result.success?

      failure("Claude probe failed: #{probe_failure_reason(result, output)}")
    end
  rescue Errno::ENOENT
    failure("Claude CLI is not installed or not on PATH.")
  end

  def probe_codex
    case credential
    when "codex_api_key"
      return missing("Codex API key is not configured.") if user.codex_api_key.blank?
      return wrong_mode("Codex is set to ChatGPT auth.json mode.") unless user.codex_auth_mode == "api_key"
    when "codex_auth_json"
      return missing("Codex ChatGPT auth.json is not configured.") if user.codex_auth_json.blank?
      return wrong_mode("Codex is set to API key mode.") unless user.codex_auth_mode == "chatgpt_login"
    end

    Dir.mktmpdir("syrus-codex-probe-") do |workspace|
      codex_home = File.join(workspace, ".codex")
      FileUtils.mkdir_p(codex_home)
      auth = CodexAuth.new(user: user, codex_home: codex_home).prepare!
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
        CodexAuth.new(user: user, codex_home: codex_home).persist_updated_auth_json
        return success(credential, "Codex credentials are valid.")
      end

      failure("Codex probe failed: #{probe_failure_reason(result, output)}")
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
