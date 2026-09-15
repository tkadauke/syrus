require "fileutils"
require "json"
require "tmpdir"

class AgyCredentialProbe
  CREDENTIAL = "agy".freeze
  SECRET_EXTRACTOR = ->(user) { user.gemini_api_key }.freeze

  def self.call(probe)
    new(probe).call
  end

  def self.refresh_for(user:, force: false)
    result = ::CredentialProbe.call(user: user, credential: CREDENTIAL)
    record_evidence!(user: user, result: result)
    result
  end

  def self.record_evidence!(user:, result:, observed_at: Time.current)
    ProviderAvailabilityEvidence.create!(
      user: user,
      provider: "agy",
      account_id: nil,
      model: AgyInvocation.configured_model,
      status: evidence_status(result),
      source: "usage_probe",
      observed_at: observed_at,
      details: ProviderAvailabilityEvidence.sanitized_details(
        message: result.message,
        snapshot: result.details.fetch(:snapshot, {})
      )
    )
  end

  def self.evidence_status(result)
    return "available" if result.ok

    result.details[:status].presence || "probe_inconclusive"
  end

  def initialize(probe)
    @probe = probe
  end

  def call
    return missing("Antigravity uses the saved Gemini API key, but no Gemini API key is configured.") if user.gemini_api_key.blank?

    Dir.mktmpdir("syrus-agy-probe-") do |workspace|
      agy_home = File.join(workspace, ".agy")
      FileUtils.mkdir_p(agy_home)
      output = +""
      result = ProcessRunner.new(
        env: ProcessRunner.forwarded_env(
          AgentInvocation::ENV_FORWARD,
          extra: agy_env(agy_home)
        ),
        command: agy_command,
        stdin_data: stdin_event,
        chdir: workspace,
        timeout: CredentialProbe::TIMEOUT_SECONDS,
        silent_timeout: 15,
        kind: "agent",
        on_output_chunk: ->(chunk) { append_output(output, chunk) }
      ).run

      if result.success?
        success("Antigravity accepted the shared Gemini API key.", details: success_details(output))
      else
        failure("Antigravity probe failed: #{probe_failure_reason(result, output)}", details: failure_details(output))
      end
    end
  rescue Errno::ENOENT
    failure("Antigravity CLI (agy) is not installed or not on PATH.", details: { status: "probe_unavailable" })
  end

  private

  attr_reader :probe

  def user = probe.send(:user)

  def missing(message)
    CredentialProbe::Result.new(credential: CREDENTIAL, ok: false, message: message, details: { status: "probe_unavailable" })
  end

  def success(message, details: {})
    CredentialProbe::Result.new(credential: CREDENTIAL, ok: true, message: message, details: details)
  end

  def failure(message, details: {})
    CredentialProbe::Result.new(credential: CREDENTIAL, ok: false, message: message, details: details)
  end

  def append_output(output, chunk) = probe.send(:append_output, output, chunk)

  def probe_failure_reason(result, output) = probe.send(:probe_failure_reason, result, output)

  def agy_env(agy_home)
    {
      "HOME" => agy_home,
      "AGY_HOME" => agy_home,
      "ANTIGRAVITY_HOME" => agy_home,
      "GEMINI_API_KEY" => user.gemini_api_key,
      "GOOGLE_API_KEY" => user.gemini_api_key,
      "SYRUS_AGY_MODEL" => AgyInvocation.configured_model,
      "AGY_MODEL" => AgyInvocation.configured_model
    }.compact
  end

  def agy_command
    [
      "agy",
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--print=",
      "--dangerously-skip-permissions",
      "--disable-slash-commands",
      "--print-timeout", "60s"
    ]
  end

  def stdin_event
    { event: "user", message: { content: "Reply with OK." } }.to_json + "\n"
  end

  def success_details(output)
    details = { shared_credential: "gemini_api_key", snapshot: {} }
    details[:model] = AgyInvocation.configured_model if AgyInvocation.configured_model.present?
    parse_usage(output)&.then { |usage| details[:usage] = usage }
    details
  end

  def failure_details(output)
    text = output.to_s
    status =
      if ProviderAuthFailure.detect?(text)
        "auth_error"
      elsif ProviderUsageLimit.detect?(text)
        "exhausted"
      elsif ProviderRateLimitEvidence.text_match?(text)
        "warning"
      else
        "probe_inconclusive"
      end
    { status: status, shared_credential: "gemini_api_key", snapshot: {} }
  end

  def parse_usage(output)
    output.to_s.lines.filter_map do |line|
      JSON.parse(line).fetch("usage", nil)
    rescue JSON::ParserError
      nil
    end.last
  end
end
