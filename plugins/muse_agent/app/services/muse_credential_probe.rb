class MuseCredentialProbe
  SECRET_EXTRACTOR = ->(user) { user.muse_api_key }.freeze

  def self.call(probe)
    new(probe).call
  end

  def initialize(probe)
    @probe = probe
  end

  def call
    return missing("Muse API key is not configured.") if user.muse_api_key.blank?

    Dir.mktmpdir("syrus-muse-probe-") do |workspace|
      output = +""
      result = Syrus::Host::ProcessRunner.new(
        env: Syrus::Host::ProcessRunner.forwarded_env(Syrus::Host::AgentRuntime.forwarded_env_keys, extra: MuseInvocation::LAUNCHER_ENV),
        command: [
          "muse", "exec",
          "--json",
          "--provider", "meta",
          "--api-key-stdin",
          "Reply with OK."
        ],
        stdin_data: user.muse_api_key,
        mounts: Syrus::Host::ProcessRunner.mounts(workspace),
        network: "agent",
        timeout: Syrus::Host::CredentialProbe::TIMEOUT_SECONDS,
        silent_timeout: 15,
        kind: "agent",
        on_output_chunk: ->(chunk) { append_output(output, chunk) }
      ).run

      return success("Muse API key is valid.") if result.success?

      failure("Muse probe failed: #{probe_failure_reason(result, output)}")
    end
  rescue Errno::ENOENT
    failure("Muse CLI is not installed or not on PATH.")
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
