class ClaudeCredentialProbe
  SECRET_EXTRACTOR = ->(user) { user.claude_oauth_token }.freeze

  def self.call(probe)
    new(probe).call
  end

  def self.cli_ready(probe)
    new(probe).call(ambient: true)
  end

  def initialize(probe)
    @probe = probe
  end

  # Probe whether `claude --print` already works on this machine using the
  # CLI's own stored login (no Syrus token injected). Lets the setup wizard
  # detect a working bare-metal subscription before asking for a token.
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

  attr_reader :probe

  def user = probe.send(:user)

  def credential = probe.send(:credential)

  def success(message) = probe.send(:success, credential, message)

  def missing(message) = probe.send(:missing, message)

  def failure(message) = probe.send(:failure, message)

  def append_output(output, chunk) = probe.send(:append_output, output, chunk)

  def probe_failure_reason(result, output) = probe.send(:probe_failure_reason, result, output)
end
