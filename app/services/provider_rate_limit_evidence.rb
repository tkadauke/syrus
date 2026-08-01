class ProviderRateLimitEvidence
  OUTCOMES = %w[rate_limited rate_limit].freeze

  TEXT_PATTERNS = [
    /\b429\b/i,
    /\btoo many requests\b/i,
    /\bquota exceeded\b/i,
    /\brate[ -](?:limit(?:ed|ing)?|limited?)\b/i
  ].freeze

  def self.direct?(run, text: nil, include_logs: true, provider_only: false)
    new(run, text: text, include_logs: include_logs, provider_only: provider_only).direct?
  end

  def self.text_match?(text)
    TEXT_PATTERNS.any? { |pattern| text.to_s.match?(pattern) }
  end

  def initialize(run, text: nil, include_logs: true, provider_only: false)
    @run = run
    @text = text
    @include_logs = include_logs
    @provider_only = provider_only
  end

  def direct?
    return true if OUTCOMES.include?(run.agent_outcome.to_s)

    return false if provider_only? && !provider_run?

    explicit_rate_limited_log? || self.class.text_match?(text.presence || provider_text)
  end

  private

  attr_reader :run, :text

  def provider_run?
    run.step.nil? || run.step&.agentic? == true
  end

  def explicit_rate_limited_log?
    include_logs? && run.job_logs.where(kind: "rate_limited").exists?
  end

  def provider_text
    [
      run.agent_summary,
      run.agent_pr_title,
      run.agent_pr_body,
      run.run_diagnostic&.error_class,
      run.run_diagnostic&.error_message,
      run.run_diagnostic&.error_backtrace
    ].compact.join("\n")
  end

  def include_logs?
    @include_logs
  end

  def provider_only?
    @provider_only
  end
end
