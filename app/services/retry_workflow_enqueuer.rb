class RetryWorkflowEnqueuer
  Result = Data.define(:workflow, :error, :circuit) do
    def success? = workflow.present?
  end

  PROVIDER_VALIDATORS = %i[configured retry_alternate none].freeze

  def self.call(...) = new(...).call

  def initialize(job:, agent_provider: nil, artifacts: nil, provider_validation: :configured, automatic: false)
    @job = job
    @agent_provider = agent_provider.to_s.presence
    @artifacts = artifacts
    @provider_validation = provider_validation.to_sym
    @automatic = automatic
  end

  def call
    validate_provider_validation!
    return failure("Runaway protection active — clear by retrying manually.") if automatic? && job.runaway_protection.present?

    eligibility = RetryWorkflowEligibility.call(job: job)
    reconcile_ready_pr! if eligibility.code == "pr_ready"
    return failure(eligibility.message) unless eligibility.eligible?
    return failure("That agent is not available for retry.") unless agent_provider_allowed?
    return circuit_failure if automatic? && provider_circuit.open?

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
          workflow = Workflows::Retry.instantiate(job: job, artifacts: artifacts, agent_provider: agent_provider)
        end
      else
        failure_result = failure(eligibility.message)
      end
    end

    return failure_result if failure_result

    StepDispatcher.start_workflow(workflow)
    Result.new(workflow: workflow, error: nil, circuit: nil)
  end

  private

  attr_reader :job, :agent_provider, :artifacts, :provider_validation

  def validate_provider_validation!
    return if PROVIDER_VALIDATORS.include?(provider_validation)

    raise ArgumentError, "unknown retry provider validation: #{provider_validation.inspect}"
  end

  def agent_provider_allowed?
    return true if agent_provider.blank?

    case provider_validation
    when :configured
      job.user.agent_provider_configured?(agent_provider)
    when :retry_alternate
      job.retry_with_agent_providers.include?(agent_provider)
    when :none
      true
    end
  end

  def automatic?
    @automatic
  end

  def effective_agent_provider
    agent_provider.presence || job.workflow_agent_provider
  end

  def provider_circuit
    @provider_circuit ||= ProviderCircuitBreaker.call(effective_agent_provider)
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

  def failure(message, circuit: nil)
    Result.new(workflow: nil, error: message, circuit: circuit)
  end
end
