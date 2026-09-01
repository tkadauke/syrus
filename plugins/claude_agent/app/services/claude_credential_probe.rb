class ClaudeCredentialProbe
  def self.call(user:, credential:)
    new(user: user, credential: credential).call
  end

  # Probe whether `claude --print` already works on this machine using the
  # CLI's own stored login (no Syrus token injected). Lets the setup wizard
  # detect a working bare-metal subscription before asking for a token.
  def self.claude_cli_ready(user: nil)
    new(user: user, credential: "claude_oauth_token").call(ambient: true)
  end

  def initialize(user:, credential:)
    @user = user
    @credential = credential
  end

  def call(ambient: false)
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
        timeout: CredentialProbe::TIMEOUT_SECONDS,
        silent_timeout: 15,
        kind: "agent",
        on_output_chunk: ->(chunk) { append_output(output, chunk) }
      ).run

      if result.success?
        return success(ambient ? "Claude already works on this machine — no token needed." : "Claude OAuth token is valid.")
      end

      message = ambient ? "Claude is not authenticated on this machine yet." : "Claude probe failed: #{probe_failure_reason(result, output)}"
      failure(message)
    end
  rescue Errno::ENOENT
    failure("Claude CLI is not installed or not on PATH.")
  end

  private

  attr_reader :user, :credential

  def success(message)
    CredentialProbe::Result.new(credential: credential, ok: true, message: message, details: {})
  end

  def missing(message)
    CredentialProbe::Result.new(credential: credential, ok: false, message: message, details: {})
  end

  def failure(message)
    CredentialProbe::Result.new(credential: credential, ok: false, message: message, details: {})
  end

  def append_output(output, chunk)
    output << chunk.to_s
    output.slice!(0, output.bytesize - CredentialProbe::MAX_OUTPUT_BYTES) if output.bytesize > CredentialProbe::MAX_OUTPUT_BYTES
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
      user&.github_token,
      user&.claude_oauth_token,
      user&.codex_api_key
    ].compact_blank.each do |secret|
      text = text.gsub(secret, CredentialProbe::REDACTED)
    end

    text.lines.map(&:strip).reject(&:blank?).last(3).join(" ").truncate(500)
  end
end
