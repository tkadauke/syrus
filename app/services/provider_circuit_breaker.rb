class ProviderCircuitBreaker
  WINDOW = 15.minutes
  OPEN_FOR = 10.minutes
  USAGE_LIMIT_WINDOW = 24.hours
  USAGE_LIMIT_OPEN_FOR = 24.hours
  MIN_FAILURES = 5
  MIN_UNRELATED_JOBS = 3
  REPEAT_SIGNATURE_THRESHOLD = 3

  RETRYABLE_OUTCOMES = %w[
    provider_transient
    rate_limited
    rate_limit
    worker_died
  ].freeze

  TRANSIENT_PATTERNS = [
    /provider[_ -]?transient/i,
    /rate.?limit/i,
    /too many requests/i,
    /\b429\b/,
    /temporar(?:y|ily)/i,
    /overloaded/i,
    /service unavailable/i,
    /upstream/i,
    /silent timeout/i,
    /timed out/i,
    /timeout/i
  ].freeze

  Decision = Data.define(:provider, :open, :reason, :retry_after, :failure_count, :job_count, :signature, :model, :usage_limit) do
    def initialize(provider:, open:, reason:, retry_after:, failure_count:, job_count:, signature:, model: nil, usage_limit: false)
      super
    end

    def open? = open
    def usage_limit? = usage_limit

    def as_json(*)
      {
        provider: provider,
        open: open?,
        reason: reason,
        retry_after: retry_after&.iso8601,
        failure_count: failure_count,
        job_count: job_count,
        signature: signature,
        model: model,
        usage_limit: usage_limit?
      }
    end
  end

  FailureSignal = Data.define(:run, :signature, :retryable)
  UsageLimitSignal = Data.define(:run, :signature, :model)

  def self.call(provider, now: Time.current) = new(provider, now: now).call

  def self.open?(provider, now: Time.current) = call(provider, now: now).open?

  def self.open_circuits(now: Time.current)
    User::AGENT_PROVIDERS.filter_map do |provider|
      decision = call(provider, now: now)
      decision if decision.open?
    end
  end

  def initialize(provider, now: Time.current)
    @provider = provider.to_s
    @now = now
  end

  def call
    usage_signal = usage_limit_signals.first
    if usage_signal
      return open_usage_limit(usage_signal)
    end

    signals = failure_signals
    return closed(signals) if signals.size < MIN_FAILURES

    job_count = signals.map { |signal| signal.run.job_id }.uniq.size
    return closed(signals, job_count: job_count) if job_count < MIN_UNRELATED_JOBS

    repeated_signature, repeated_count = repeated_signature(signals)
    if repeated_signature && repeated_count >= REPEAT_SIGNATURE_THRESHOLD
      return open(signals, job_count: job_count, reason: "repeated upstream error", signature: repeated_signature)
    end

    open(signals, job_count: job_count, reason: "provider transient failures")
  end

  private

  attr_reader :provider, :now

  def closed(signals, job_count: nil)
    Decision.new(
      provider: provider,
      open: false,
      reason: nil,
      retry_after: nil,
      failure_count: signals.count,
      job_count: job_count || signals.map { |signal| signal.run.job_id }.uniq.size,
      signature: nil,
      model: nil,
      usage_limit: false
    )
  end

  def open(signals, job_count:, reason:, signature: nil)
    latest_finished_at = signals.map { |signal| signal.run.finished_at || signal.run.updated_at }.compact.max || now
    Decision.new(
      provider: provider,
      open: true,
      reason: reason,
      retry_after: latest_finished_at + OPEN_FOR,
      failure_count: signals.count,
      job_count: job_count,
      signature: signature,
      model: nil,
      usage_limit: false
    )
  end

  def open_usage_limit(signal)
    latest_finished_at = signal.run.finished_at || signal.run.updated_at || now
    Decision.new(
      provider: provider,
      open: true,
      reason: signal.model.present? ? "provider usage limit exhausted for model #{signal.model}" : "provider usage limit exhausted; model unknown, failing closed for provider",
      retry_after: latest_finished_at + USAGE_LIMIT_OPEN_FOR,
      failure_count: 1,
      job_count: 1,
      signature: signal.signature,
      model: signal.model,
      usage_limit: true
    )
  end

  def failure_signals
    recent_failed_runs.filter_map do |run|
      signal = FailureSignal.new(run: run, signature: signature_for(run), retryable: retryable?(run))
      signal if signal.retryable
    end
  end

  def recent_failed_runs
    Run.left_outer_joins(:run_diagnostic)
       .includes(:run_diagnostic)
       .where(state: "failed", agent_provider: provider)
       .where("runs.finished_at >= ?", now - WINDOW)
  end

  def usage_limit_signals
    usage_limit_failed_runs.filter_map do |run|
      text = diagnostic_text(run)
      next unless usage_limit?(run, text)

      UsageLimitSignal.new(
        run: run,
        signature: signature_for(run),
        model: ProviderUsageLimit.extract_model(text)
      )
    end
  end

  def usage_limit_failed_runs
    Run.left_outer_joins(:run_diagnostic, :run_failure_classification)
       .includes(:run_diagnostic, :run_failure_classification)
       .where(state: "failed", agent_provider: provider)
       .where("runs.finished_at >= ?", now - USAGE_LIMIT_WINDOW)
       .order(finished_at: :desc, updated_at: :desc)
  end

  def usage_limit?(run, text)
    run.agent_outcome.to_s == ProviderUsageLimit::OUTCOME ||
      run.run_failure_classification&.classification == ProviderUsageLimit::CLASSIFICATION ||
      ProviderUsageLimit.detect?(text)
  end

  def retryable?(run)
    return true if RETRYABLE_OUTCOMES.include?(run.agent_outcome.to_s)
    return true if transient_text?(diagnostic_text(run))
    return true if run.job_logs.where(kind: "rate_limited").exists?

    false
  end

  def transient_text?(text)
    TRANSIENT_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def diagnostic_text(run)
    [
      run.agent_outcome,
      run.run_failure_classification&.classification,
      run.run_diagnostic&.error_class,
      run.run_diagnostic&.error_message,
      recent_log_text(run)
    ].compact.join(" ")
  end

  def signature_for(run)
    raw = [
      run.agent_outcome,
      run.run_failure_classification&.classification,
      run.run_diagnostic&.error_class,
      run.run_diagnostic&.error_message,
      recent_log_text(run)
    ].compact.join(": ")
    normalized = raw.downcase
                    .gsub(%r{https?://\S+}, "<url>")
                    .gsub(/\b[0-9a-f]{8,}\b/, "<hex>")
                    .gsub(/\b\d+\b/, "<num>")
                    .squish
    normalized.presence || "unknown transient failure"
  end

  def repeated_signature(signals)
    signals.group_by(&:signature)
           .max_by { |_signature, grouped| grouped.size }
           &.then { |signature, grouped| [ signature, grouped.size ] }
  end

  def recent_log_text(run)
    run.job_logs.order(sequence: :desc).limit(5).pluck(:chunk).join(" ")
  end
end
