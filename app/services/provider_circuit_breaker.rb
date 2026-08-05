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
  ].freeze

  TRANSIENT_PATTERNS = [
    /provider[_ -]?transient/i,
    /\brate[ -](?:limit(?:ed|ing)?|limited?)\b/i,
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

  Decision = Data.define(:provider, :open, :reason, :retry_after, :failure_count, :job_count, :signature, :model, :usage_limit, :evidence) do
    def initialize(provider:, open:, reason:, retry_after:, failure_count:, job_count:, signature:, model: nil, usage_limit: false, evidence: nil)
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
        usage_limit: usage_limit?,
        evidence: evidence
      }
    end
  end

  FailureSignal = Data.define(:run, :signature, :retryable)
  UsageLimitSignal = Data.define(:run, :signature, :model, :evidence)

  def self.call(provider, now: Time.current, include_logs: true) = new(provider, now: now, include_logs: include_logs).call

  def self.open?(provider, now: Time.current) = call(provider, now: now).open?

  def self.open_circuits(now: Time.current)
    User::AGENT_PROVIDERS.filter_map do |provider|
      decision = call(provider, now: now)
      decision if decision.open?
    end
  end

  def initialize(provider, now: Time.current, include_logs: true)
    @provider = provider.to_s
    @now = now
    @include_logs = include_logs
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
      usage_limit: false,
      evidence: nil
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
      usage_limit: false,
      evidence: latest_provider_evidence_payload
    )
  end

  def open_usage_limit(signal)
    latest_finished_at = signal.run ? (signal.run.finished_at || signal.run.updated_at || now) : (signal.evidence&.observed_at || now)
    retry_after = signal.run ? ProviderQuotaReset.retry_after_for_run(signal.run, now: now) : nil
    retry_after ||= latest_finished_at + USAGE_LIMIT_OPEN_FOR
    Decision.new(
      provider: provider,
      open: true,
      reason: signal.model.present? ? "provider usage limit exhausted for model #{signal.model}" : "provider usage limit exhausted; model unknown, failing closed for provider",
      retry_after: retry_after,
      failure_count: 1,
      job_count: 1,
      signature: signal.signature,
      model: signal.model,
      usage_limit: true,
      evidence: usage_signal_summary(signal) || latest_provider_evidence_payload
    )
  end

  def failure_signals
    recent_failed_runs.filter_map do |run|
      next if run.run_failure_classification&.repaired_for_circuit?
      next if positive_provider_evidence_after?(run)

      signal = FailureSignal.new(run: run, signature: signature_for(run), retryable: retryable?(run))
      signal if signal.retryable
    end
  end

  def recent_failed_runs
    Run.left_outer_joins(:run_diagnostic)
       .includes(:run_diagnostic, :run_failure_classification)
       .where(state: "failed", agent_provider: provider)
       .where("runs.finished_at >= ?", now - WINDOW)
  end

  def usage_limit_signals
    current_usage_limit_evidence&.then do |evidence|
      return [
        UsageLimitSignal.new(
          run: evidence.run,
          signature: evidence.source,
          model: evidence.model,
          evidence: evidence
        )
      ]
    end

    usage_limit_failed_runs.filter_map do |run|
      next if run.run_failure_classification&.repaired_for_circuit?

      text = diagnostic_text(run)
      next unless usage_limit?(run, text)
      retry_after = ProviderQuotaReset.retry_after_for_run(run, now: now)
      next if retry_after && retry_after <= now
      model = ProviderUsageLimit.extract_model(text)
      next if provider == "codex" && ProviderAvailabilityEvidence.suppressed_by_positive_after?(
        user: run.user,
        provider: provider,
        account_id: CodexAccountScope.for_user(run.user),
        model: model,
        observed_at: run.finished_at || run.updated_at || now
      )

      UsageLimitSignal.new(
        run: run,
        signature: signature_for(run),
        model: model,
        evidence: nil
      )
    end
  end

  def current_usage_limit_evidence
    return unless provider == "codex"

    ProviderAvailabilityEvidence
      .where(provider: provider, status: "exhausted")
      .unrepaired_for_circuit
      .where("observed_at >= ?", now - USAGE_LIMIT_WINDOW)
      .recent
      .detect do |evidence|
        next false if false_positive_codex_evidence?(evidence)

        !ProviderAvailabilityEvidence.suppressed_by_positive_after?(
          user: evidence.user,
          provider: provider,
          account_id: evidence.account_id,
          model: evidence.model,
          observed_at: evidence.observed_at
        )
      end
  end

  def false_positive_codex_evidence?(evidence)
    ProviderAvailabilityEvidence.false_positive_codex_usage_limit?(
      evidence.details&.dig("message"),
      model: evidence.model
    )
  end

  def usage_limit_failed_runs
    Run.left_outer_joins(:run_diagnostic, :run_failure_classification)
       .includes(:run_diagnostic, :run_failure_classification, :step)
       .where(state: "failed", agent_provider: provider)
       .where("runs.finished_at >= ?", now - USAGE_LIMIT_WINDOW)
       .order(finished_at: :desc, updated_at: :desc)
  end

  def usage_limit?(run, text)
    return false if run.run_failure_classification&.repaired_for_circuit?
    return false if ProviderUsageLimit.inconclusive?(text)
    return true if run.agent_outcome.to_s == ProviderUsageLimit::OUTCOME
    return false unless ProviderUsageLimit.run_can_exhaust_provider?(run)

    (
      run.run_failure_classification&.classification == ProviderUsageLimit::CLASSIFICATION ||
      ProviderUsageLimit.detect?(text)
    )
  end

  def retryable?(run)
    return false if run.run_failure_classification&.repaired_for_circuit?
    return false if positive_provider_evidence_after?(run)

    return true if RETRYABLE_OUTCOMES.include?(run.agent_outcome.to_s)
    return true if run.run_failure_classification&.classification == "provider_transient"
    if run.run_failure_classification&.classification == "rate_limited"
      return true if ProviderRateLimitEvidence.direct?(run, include_logs: include_logs?, provider_only: true)
    end

    return true if transient_text?(diagnostic_text(run))
    return false unless include_logs?

    return true if ProviderRateLimitEvidence.direct?(run, text: "", include_logs: true, provider_only: true)

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
      include_logs? ? recent_log_text(run) : nil
    ].compact.join(" ")
  end

  def signature_for(run)
    raw = [
      run.agent_outcome,
      run.run_failure_classification&.classification,
      run.run_diagnostic&.error_class,
      run.run_diagnostic&.error_message,
      include_logs? ? recent_log_text(run) : nil
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

  def positive_provider_evidence_after?(run)
    observed_at = run.finished_at || run.updated_at
    return false unless observed_at

    ProviderAvailabilityEvidence
      .where(provider: provider)
      .positive
      .where("observed_at > ?", observed_at)
      .exists?
  end

  def include_logs?
    @include_logs
  end

  def latest_provider_evidence_payload
    return unless provider == "codex"

    ProviderAvailabilityEvidence.latest_positive_negative_for_provider(provider)
  end

  def usage_signal_summary(signal)
    return signal.evidence.summary if signal.evidence
    return unless signal.run

    {
      status: "exhausted",
      source: "failed_run",
      observed_at: (signal.run.finished_at || signal.run.updated_at)&.iso8601,
      provider: provider,
      account_id: CodexAccountScope.for_user(signal.run.user),
      model: signal.model,
      run_id: signal.run.id
    }.tap do |payload|
      payload[:repair] = signal.run.run_failure_classification&.repair_summary
    end.compact
  end
end
