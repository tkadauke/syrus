class ProviderCircuitInspector
  FAILED_RUN_LIMIT = 50
  EVIDENCE_LIMIT = 50

  def self.call(provider:, user: nil, now: Time.current)
    new(provider: provider, user: user, now: now).call
  end

  def initialize(provider:, user: nil, now: Time.current)
    @provider = provider.to_s
    @user = user
    @now = now
  end

  def call
    decision.as_json.merge(
      provider: provider,
      decision: decision.as_json,
      runs: failed_runs.map { |run| run_payload(run) },
      evidence_records: evidence_records.map(&:summary),
      consumers: consumers
    )
  end

  private

  attr_reader :provider, :user, :now

  def decision
    @decision ||= ProviderCircuitBreaker.call(provider, now: now)
  end

  def failed_runs
    scope = Run.left_outer_joins(:run_diagnostic, :run_failure_classification)
      .includes(:run_diagnostic, :run_failure_classification, :job, step: :workflow)
      .where(state: "failed", agent_provider: provider)
      .where("runs.finished_at >= ?", now - ProviderCircuitBreaker::USAGE_LIMIT_WINDOW)
      .order(finished_at: :desc, updated_at: :desc, id: :desc)
      .limit(FAILED_RUN_LIMIT)
    scope = scope.where(user_id: user.id) if user
    scope
  end

  def evidence_records
    scope = ProviderAvailabilityEvidence
      .includes(:user, :run)
      .where(provider: provider)
      .where("observed_at >= ?", now - ProviderCircuitBreaker::USAGE_LIMIT_WINDOW)
      .recent
      .limit(EVIDENCE_LIMIT)
    scope = scope.where(user: user) if user
    scope
  end

  def run_payload(run)
    text = diagnostic_text(run)
    retry_after = ProviderQuotaReset.retry_after_for_run(run, now: now)
    retry_after ||= (run.finished_at || run.updated_at || now) + ProviderCircuitBreaker::USAGE_LIMIT_OPEN_FOR if usage_limit_run?(run, text)
    {
      id: run.id,
      job_id: run.job_id,
      job_slug: run.job&.slug,
      workflow_id: run.workflow_id,
      step_id: run.step_id,
      step_kind: run.step&.kind,
      trigger_kind: run.trigger_kind,
      agent_provider: run.agent_provider,
      agent_outcome: run.agent_outcome,
      finished_at: run.finished_at&.iso8601,
      extracted_model: ProviderUsageLimit.extract_model(text),
      retry_after: retry_after&.iso8601,
      diagnostic: diagnostic_payload(run.run_diagnostic),
      classification: classification_payload(run.run_failure_classification),
      circuit_usage_limit_candidate: usage_limit_run?(run, text),
      circuit_retryable_candidate: retryable_run?(run)
    }.compact
  end

  def diagnostic_payload(diagnostic)
    return unless diagnostic

    {
      id: diagnostic.id,
      error_class: diagnostic.error_class,
      error_message: diagnostic.error_message
    }.compact
  end

  def classification_payload(classification)
    return unless classification

    {
      id: classification.id,
      classification: classification.classification,
      confidence: classification.confidence,
      retryable: classification.retryable,
      reason: classification.reason,
      diagnostic_summary: classification.diagnostic_summary,
      classified_at: classification.classified_at&.iso8601,
      classifier_inputs: classification.classifier_inputs,
      repair: classification.repair_summary
    }.compact
  end

  def consumers
    {
      queued_workflows_without_runs: queued_workflows_without_runs,
      delayed_auto_retries: delayed_auto_retries
    }
  end

  def queued_workflows_without_runs
    scope = Workflow
      .includes(:job)
      .where(agent_provider: provider, state: "queued")
      .where.not(id: Workflow.joins(steps: :runs).select("workflows.id"))
      .order(created_at: :asc)
      .limit(50)
    scope = scope.where(user_id: user.id) if user
    scope.map do |workflow|
      {
        workflow_id: workflow.id,
        job_id: workflow.job_id,
        job_slug: workflow.job&.slug,
        trigger_kind: workflow.trigger_kind,
        start_blocked_reason: workflow.artifact("start_blocked_reason"),
        start_blocked_details: workflow.artifact("start_blocked_details"),
        next_check_at: workflow.artifact("start_blocked_next_check_at")
      }.compact
    end
  end

  def delayed_auto_retries
    scope = AutoRetryAttempt
      .includes(:job)
      .where(agent_provider: provider, performed_at: nil, skipped_reason: nil)
      .where("scheduled_at > ?", now)
      .order(:scheduled_at)
      .limit(50)
    scope = scope.joins(:job).where(jobs: { user_id: user.id }) if user
    scope.map do |attempt|
      {
        auto_retry_attempt_id: attempt.id,
        job_id: attempt.job_id,
        job_slug: attempt.job&.slug,
        workflow_id: attempt.workflow_id,
        run_id: attempt.run_id,
        retry_kind: attempt.retry_kind,
        scheduled_at: attempt.scheduled_at&.iso8601,
        failure_classification: attempt.failure_classification
      }.compact
    end
  end

  def usage_limit_run?(run, text)
    return false if run.run_failure_classification&.repaired_for_circuit?
    return false if ProviderUsageLimit.inconclusive?(text)
    return true if run.agent_outcome.to_s == ProviderUsageLimit::OUTCOME
    return false unless ProviderUsageLimit.run_can_exhaust_provider?(run)

    run.run_failure_classification&.classification == ProviderUsageLimit::CLASSIFICATION ||
      ProviderUsageLimit.detect?(text)
  end

  def retryable_run?(run)
    return false if run.run_failure_classification&.repaired_for_circuit?

    ProviderCircuitBreaker::RETRYABLE_OUTCOMES.include?(run.agent_outcome.to_s) ||
      run.run_failure_classification&.classification.in?(%w[provider_transient rate_limited])
  end

  def diagnostic_text(run)
    [
      run.agent_outcome,
      run.run_failure_classification&.classification,
      run.run_diagnostic&.error_class,
      run.run_diagnostic&.error_message
    ].compact.join(" ")
  end
end
