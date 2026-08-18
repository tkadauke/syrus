class SmartRetryEnqueuer
  ACTION_LABELS = {
    resume_failed_step: "resumed failed step",
    failed_step: "failed step retried",
    landing: "landing retried",
    implementation: "implementation retried"
  }.freeze

  SKIP_LABELS = {
    closed: "closed",
    approved: "approved",
    no_change_needed: "no change needed",
    pr_ready: "PR ready",
    duplicate_retry: "duplicate retry",
    active_run: "active run",
    provider_circuit: "provider circuit",
    not_retryable: "not retryable"
  }.freeze

  Result = Data.define(:job, :action, :workflow, :run, :error, :reason, :circuit) do
    def success? = action.present?
    def skipped? = !success?
  end

  BatchResult = Data.define(:results) do
    def successes = results.select(&:success?)
    def skipped = results.select(&:skipped?)
    def success? = successes.any?
    def affected_job_ids = successes.map { |result| result.job.id }

    def counts_by_action
      count_by(successes, :action)
    end

    def skipped_by_reason
      count_by(skipped, :reason)
    end

    def action_summary
      counts_by_action.transform_keys { |key| ACTION_LABELS.fetch(key, key.to_s.humanize.downcase) }
    end

    def skip_summary
      skipped_by_reason.transform_keys { |key| SKIP_LABELS.fetch(key, key.to_s.humanize.downcase) }
    end

    def first_error
      skipped.map(&:error).compact.first
    end

    private

    def count_by(items, attribute)
      items.each_with_object(Hash.new(0)) do |item, counts|
        value = item.public_send(attribute)
        counts[value] += 1 if value.present?
      end
    end
  end

  def self.call(...) = new(...).call
  def self.call_many(jobs:, **options)
    BatchResult.new(results: jobs.map { |job| call(job: job, **options) })
  end

  def initialize(job:, agent_provider: nil, provider_validation: :configured, automatic: true, by_user: nil)
    @job = job
    @agent_provider = agent_provider.to_s.presence
    @provider_validation = provider_validation
    @automatic = automatic
    @by_user = by_user
  end

  def call
    return skipped(:closed, closed_job_message) if job.closed?
    return skipped(:no_change_needed, "Job has no changes to retry.") if job.no_change_needed?
    return skipped(:pr_ready, "PR is already current and checks are passing.") if pr_ready?
    return skipped(:active_run, "A Run is already in progress - wait for it to finish.") if job.any_active_run?
    return skipped(:duplicate_retry, "A retry workflow is already queued or running for this Job.") if duplicate_active_retry_workflow?
    return provider_circuit_skip if automatic? && provider_circuit.open?

    resume_failed_step || retry_diverged_pr_open_as_new_workflow || retry_failed_step_or_landing || retry_landing || approved_landing_skip || retry_implementation
  end

  private

  attr_reader :job, :agent_provider, :provider_validation, :by_user

  def latest_workflow
    @latest_workflow ||= job.latest_workflow
  end

  def failed_step
    @failed_step ||= RetryFailedStepEnqueuer.failed_step_for(latest_workflow) if latest_workflow&.failed?
  end

  def failed_run
    @failed_run ||= failed_step&.runs&.where(state: "failed")&.reorder(created_at: :desc, id: :desc)&.first
  end

  def session
    @session ||= failed_run&.provider_session
  end

  def automatic?
    @automatic
  end

  def effective_agent_provider
    agent_provider.presence || session&.provider.presence || latest_workflow&.agent_provider.presence || job.workflow_agent_provider
  end

  def provider_circuit
    @provider_circuit ||= ProviderCircuitBreaker.call(effective_agent_provider)
  end

  def provider_circuit_skip
    label = App::Presentation.agent_provider_label(provider_circuit.provider)
    until_text = provider_circuit.retry_after ? " until #{provider_circuit.retry_after.to_fs(:db)}" : ""
    skipped(:provider_circuit, "#{label} appears degraded#{until_text}; automatic retries are paused.", circuit: provider_circuit)
  end

  def duplicate_active_retry_workflow?
    job.workflows.active.where(trigger_kind: "retry").exists?
  end

  def closed_job_message
    if job.infrastructure?
      "Thread is closed - use Start over to begin a new one."
    else
      "Thread is closed - reopen it to continue."
    end
  end

  def pr_ready?
    job.pr_number.present? &&
      job.branch_name.present? &&
      job.commits_behind_base.to_i.zero? &&
      job.pr_checks_state == "passing"
  end

  def resume_failed_step
    return unless latest_workflow&.retry_available?
    return unless failed_step&.agentic?
    return unless session

    result = RetryFailedStepEnqueuer.call(
      workflow: latest_workflow,
      parent_session_id: session.session_id,
      prompt: Prompts::Resume.new.to_s,
      agent_provider: session.provider.presence || effective_agent_provider
    )
    return skipped(:not_retryable, result.error) unless result.success?

    succeeded(:resume_failed_step, result)
  end

  def retry_diverged_pr_open_as_new_workflow
    return unless branch_diverged_pr_open?

    retry_implementation
  end

  def retry_failed_step_or_landing
    return unless latest_workflow&.retry_available?
    return unless failed_step

    result = RetryFailedStepEnqueuer.call(workflow: latest_workflow, agent_provider: effective_agent_provider)
    return skipped(:not_retryable, result.error) unless result.success?

    succeeded(latest_workflow.landing_workflow? ? :landing : :failed_step, result)
  end

  def retry_landing
    return unless job.landing_failure_reason.present?

    return retry_epic_merge_train_landing if job.approved? && AppSetting.merge_train_enabled? && job.epic_id.present?
    return retry_merge_train_landing if latest_workflow&.trigger_kind == "merge_train"
    return retry_approved_auto_merge_landing if job.approved?
    return retry_auto_merge_landing if job.may_approve?

    skipped(:not_retryable, "Landing failed - retry the failed landing workflow or reapprove the Job.")
  end

  def retry_merge_train_landing
    return skipped(:not_retryable, "Failed merge-train workflow is not available for rebuild.") unless latest_workflow&.retry_available?

    result = RetryFailedStepEnqueuer.call(workflow: latest_workflow, agent_provider: effective_agent_provider)
    return skipped(:not_retryable, result.error) unless result.success?

    succeeded(:landing, result)
  end

  def retry_auto_merge_landing
    job.approve!(via: "bulk", by_user: by_user)
    LandingQueueProcessorJob.perform_later
    succeeded(:landing, workflow: latest_workflow)
  end

  def retry_approved_auto_merge_landing
    LandingQueueProcessorJob.perform_later
    succeeded(:landing, workflow: latest_workflow)
  end

  def retry_epic_merge_train_landing
    LandingQueueReentry.call(job)
    succeeded(:landing, workflow: latest_workflow)
  end

  def approved_landing_skip
    skipped(:approved, "Job is already approved for landing.") if job.approved? || job.landing?
  end

  def retry_implementation
    result = RetryWorkflowEnqueuer.call(
      job: job,
      agent_provider: agent_provider,
      provider_validation: provider_validation,
      automatic: automatic?
    )
    return skipped(:not_retryable, result.error, circuit: result.circuit) unless result.success?

    succeeded(:implementation, result)
  end

  def branch_diverged_pr_open?
    failed_step&.kind == "pr_open" &&
      failed_run_classification == "branch_diverged"
  end

  def failed_run_classification
    return nil unless failed_run

    failed_run.run_failure_classification&.classification ||
      RunFailureClassifier.classify(failed_run).classification
  end

  def succeeded(action, result = nil, workflow: nil)
    Result.new(
      job: job,
      action: action,
      workflow: workflow || result&.workflow,
      run: result.respond_to?(:run) ? result.run : nil,
      error: nil,
      reason: nil,
      circuit: nil
    )
  end

  def skipped(reason, error, circuit: nil)
    Result.new(job: job, action: nil, workflow: nil, run: nil, error: error, reason: reason, circuit: circuit)
  end
end
