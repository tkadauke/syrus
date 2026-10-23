class ProviderAvailabilityWakeup
  def self.call(provider:, user:, force: false)
    new(provider: provider, user: user, force: force).call
  end

  def initialize(provider:, user:, force: false)
    @provider = provider.to_s
    @user = user
    @force = force
  end

  def call
    provider_paused_workflows.each do |workflow|
      WorkflowPhaseAdmissionJob.enqueue_once(workflow.id, force: force || routing_hold_workflow_ids.include?(workflow.id))
    end
    LandingQueueProcessorJob.perform_later if provider_paused_workflows.any?(&:landing_workflow?)
  end

  private

  attr_reader :provider, :user, :force

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
    @provider_paused_workflows ||= (work_unit_workflows + routing_hold_workflows).uniq(&:id)
  end

  def routing_hold_workflows
    ProviderRoutingHold
      .automatic
      .joins(workflow: :job)
      .where(workflows: { user_id: user.id, state: %w[queued running] })
      .includes(:workflow)
      .select { |hold| hold_uses_provider?(hold) }
      .map(&:workflow)
  end

  def hold_uses_provider?(hold)
    configured_provider = hold.condition_evidence.to_h.dig("conditions", "usage", "actual", "provider")
    configured_provider.blank? || configured_provider == provider
  end

  def routing_hold_workflow_ids
    @routing_hold_workflow_ids ||= routing_hold_workflows.map(&:id).to_set
  end
end
