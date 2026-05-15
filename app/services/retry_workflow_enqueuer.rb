class RetryWorkflowEnqueuer
  Result = Data.define(:workflow, :error) do
    def success? = workflow.present?
  end

  PROVIDER_VALIDATORS = %i[configured retry_alternate none].freeze

  def self.call(...) = new(...).call

  def initialize(job:, agent_provider: nil, artifacts: nil, provider_validation: :configured)
    @job = job
    @agent_provider = agent_provider.to_s.presence
    @artifacts = artifacts
    @provider_validation = provider_validation.to_sym
  end

  def call
    validate_provider_validation!
    return failure("Thread is closed — use Start over to begin a new one.") if job.closed?
    return failure("A Run is already in progress — wait for it to finish.") if job.any_active_run?
    return failure("That agent is not available for retry.") unless agent_provider_allowed?

    job.switch_agent_provider!(agent_provider) if agent_provider.present?
    job.sync_skip_prepare_from_source!
    workflow = Workflows::Retry.instantiate(job: job, artifacts: artifacts, agent_provider: agent_provider)
    StepDispatcher.start_workflow(workflow)
    Result.new(workflow: workflow, error: nil)
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

  def failure(message)
    Result.new(workflow: nil, error: message)
  end
end
