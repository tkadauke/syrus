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
    eligibility = RetryWorkflowEligibility.call(job: job)
    return failure(eligibility.message) unless eligibility.eligible?
    return failure("That agent is not available for retry.") unless agent_provider_allowed?
    return circuit_failure if automatic? && provider_circuit.open?

    job.sync_skip_prepare_from_source!
    state_error = prepare_job_state_for_retry
    return failure(state_error) if state_error

    workflow = Workflows::Retry.instantiate(job: job, artifacts: artifacts, agent_provider: agent_provider)
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
    # If the Job is :failed, transition back to :queued so the new
    # workflow's Workflow#start can drive Job state :queued → :running
    # via propagate_start_to_job!. Without this, the start callback's
    # may_start_running? guard returns false (start_running only
    # transitions from :queued / :implemented), the Job sits at :failed
    # forever, and successive Retry clicks bounce off `any_active_run?`
    # once the new Run starts piling up.
    if job.failed?
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

  def failure(message, circuit: nil)
    Result.new(workflow: nil, error: message, circuit: circuit)
  end
end
