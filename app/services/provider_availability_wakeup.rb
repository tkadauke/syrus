class ProviderAvailabilityWakeup
  def self.call(provider:, user:)
    new(provider: provider, user: user).call
  end

  def initialize(provider:, user:)
    @provider = provider.to_s
    @user = user
  end

  def call
    provider_paused_workflows.each do |workflow|
      WorkflowPhaseAdmissionJob.enqueue_once(workflow.id)
    end
    LandingQueueProcessorJob.perform_later if provider_paused_workflows.any?(&:landing_workflow?)
  end

  private

  attr_reader :provider, :user

  def work_unit_workflows
    WorkUnit
      .joins(:workflow)
      .where(
        state: "blocked",
        blocked_reason: WorkUnits::Gates::ProviderAvailability::REASON,
        workflows: {
          user_id: user.id,
          agent_provider: provider,
          state: %w[queued running]
        }
      )
      .includes(:workflow)
      .order(:id)
      .map(&:workflow)
  end

  def workflows
    work_unit_workflows
  end

  def provider_paused_workflows
    @provider_paused_workflows ||= work_unit_workflows.uniq(&:id)
  end
end
