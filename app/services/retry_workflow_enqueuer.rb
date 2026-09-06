class RetryWorkflowEnqueuer
  # Maintenance workflows that a retry should re-run AS THEMSELVES rather than
  # escalating to the initial chain.
  #
  # Retrying used to always instantiate "retry", whatever had failed. A rebase
  # whose force_push failed therefore re-ran prepare, implement, both reviews,
  # every grader and pr_open -- discarding a finished, PR-opened implementation
  # to recover from a failed push. Re-running the rebase is both correct and
  # orders of magnitude cheaper.
  #
  # Deliberately only the pure-maintenance kinds. auto_merge and merge_train own
  # job lifecycle and have their own retry paths (EpicLandingRetrier), so they
  # are not in scope here.
  SELF_RETRYING_TRIGGER_KINDS = %w[ rebase stack_rebase ].freeze

  Result = Data.define(:workflow, :error, :circuit) do
    def success? = workflow.present?
  end

  class ProviderValidation
    MODES = {
      configured: "RetryWorkflowEnqueuer::ProviderValidation::Configured",
      retry_alternate: "RetryWorkflowEnqueuer::ProviderValidation::RetryAlternate",
      none: "RetryWorkflowEnqueuer::ProviderValidation::None"
    }.freeze

    def self.for(mode)
      MODES.fetch(mode.to_sym).constantize
    rescue KeyError
      raise ArgumentError, "unknown retry provider validation: #{mode.inspect}"
    end

    def initialize(job)
      @job = job
    end

    def agent_provider_allowed?(_agent_provider)
      raise NotImplementedError
    end

    private

    attr_reader :job
  end

  class ProviderValidation::Configured < ProviderValidation
    def agent_provider_allowed?(agent_provider)
      job.user.agent_provider_configured?(agent_provider)
    end
  end

  class ProviderValidation::RetryAlternate < ProviderValidation
    def agent_provider_allowed?(agent_provider)
      job.retry_with_agent_providers.include?(agent_provider)
    end
  end

  class ProviderValidation::None < ProviderValidation
    def agent_provider_allowed?(_agent_provider)
      true
    end
  end

  def self.call(...) = new(...).call

  def initialize(job:, agent_provider: nil, artifacts: nil, provider_validation: :configured, automatic: false)
    @job = job
    @agent_provider = agent_provider.to_s.presence
    @artifacts = artifacts
    @provider_validation = ProviderValidation.for(provider_validation).new(job)
    @automatic = automatic
  end

  def call
    return failure("Runaway protection active — clear by retrying manually.") if automatic? && job.runaway_protection.present?

    eligibility = RetryWorkflowEligibility.call(job: job)
    reconcile_ready_pr! if eligibility.code == "pr_ready"
    return failure(eligibility.message) unless eligibility.eligible?
    return failure("That agent is not available for retry.") unless agent_provider_allowed?
    return circuit_failure if automatic? && provider_circuit.open? && !provider_failover_candidate?

    job.sync_skip_prepare_from_source!

    failure_result = nil
    workflow = nil
    job.with_lock do
      job.reload
      eligibility = RetryWorkflowEligibility.call(job: job)
      reconcile_ready_pr! if eligibility.code == "pr_ready"
      if eligibility.eligible?
        state_error = prepare_job_state_for_retry
        if state_error
          failure_result = failure(state_error)
        else
          workflow = instantiate_retry_workflow
        end
      else
        failure_result = failure(eligibility.message)
      end
    end

    return failure_result if failure_result

    WorkUnits::Launcher.start!(workflow)
    Result.new(workflow: workflow, error: nil, circuit: nil)
  rescue WorkUnits::Launcher::LockConflict
    failure("a workflow is already queued or running for this job")
  end

  private

  attr_reader :job, :agent_provider, :artifacts, :provider_validation

  def agent_provider_allowed?
    return true if agent_provider.blank?

    provider_validation.agent_provider_allowed?(agent_provider)
  end

  def automatic?
    @automatic
  end

  def effective_agent_provider
    agent_provider.presence || job.workflow_agent_provider
  end

  def provider_circuit
    @provider_circuit ||= ProviderCircuitBreaker.call(effective_agent_provider, include_logs: false)
  end

  def provider_failover_candidate?
    job.agent_provider_failover_candidates(cause: retry_failover_cause).any?
  end

  def retry_failover_cause
    attempt = AutoRetryAttempt.find_by(id: artifacts.to_h["auto_retry_attempt_id"])
    return "rate_limited" if attempt&.failure_classification == "rate_limited"
    return "usage_exhausted" if attempt&.failure_classification == ProviderUsageLimit::CLASSIFICATION

    "provider_transient"
  end

  def circuit_failure
    failure(provider_circuit_message, circuit: provider_circuit)
  end

  def provider_circuit_message
    label = App::Presentation.agent_provider_label(provider_circuit.provider)
    until_text = provider_circuit.retry_after ? " until #{provider_circuit.retry_after.to_fs(:db)}" : ""
    "#{label} appears degraded#{until_text}; automatic retries are paused."
  end

  def prepare_job_state_for_retry
    # A manual retry clears runaway protection and resets the workflow-count
    # watermark so the fresh attempt starts with a clean counter.
    if job.runaway_protection.present? && !automatic?
      job.update!(
        runaway_protection:    nil,
        runaway_protection_at: nil,
        reopened_at:           Time.current
      )
    end

    # If the Job is :failed, or still stale-:running after a cancelled
    # workflow, transition back to :queued so the new workflow starts from
    # a coherent parent state before Workflow#start drives it active again.
    if job.failed? || job.running?
      return "Job is not ready to retry yet." unless job.may_retry_after_failure?

      job.retry_after_failure!
      job.save!
    elsif job.triaging?
      return "Job is not ready to retry yet." unless job.may_queue_reopened_retry?

      job.queue_reopened_retry!
      job.save!
    end

    nil
  end

  def reconcile_ready_pr!
    return unless job.failed? && job.may_retry_after_failure?

    job.retry_after_failure!
    job.mark_implemented! if job.may_mark_implemented?
    job.save!
  end

  def instantiate_retry_workflow
    checkpoint_resume = RunCheckpointResume.call(job: job, agent_provider: agent_provider, artifacts: artifacts)
    return checkpoint_resume.workflow if checkpoint_resume.success?

    WorkUnits::Launcher.instantiate(kind: retry_kind, job: job, artifacts: artifacts, agent_provider: agent_provider)
  end

  # The kind of the most recent failed workflow, when re-running it is the right
  # remedy; otherwise the initial-chain retry.
  def retry_kind
    kind = job.workflows.where(state: "failed").order(:created_at, :id).last&.trigger_kind
    SELF_RETRYING_TRIGGER_KINDS.include?(kind) ? kind : "retry"
  end

  def failure(message, circuit: nil)
    Result.new(workflow: nil, error: message, circuit: circuit)
  end
end
