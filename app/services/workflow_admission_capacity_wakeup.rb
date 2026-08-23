class WorkflowAdmissionCapacityWakeup
  DEFAULT_LIMIT = 8
  ARTIFACT_PATTERNS = [
    "%#{StepDispatcher::ADMISSION_BLOCK_REASON}%",
    "%workflow admission budget%",
    "%#{StepDispatcher::PAUSE_REASON_RESOURCE_SAFETY}%"
  ].freeze

  Result = Data.define(:workflow_ids) do
    def workflow_count = workflow_ids.size
  end

  def self.call(...) = new(...).call

  def self.deferred_sleepers_exist?
    sleeper_scope.exists?
  end

  def self.admission_or_resource_paused?(workflow)
    admission_or_resource_reason?(workflow.artifact("start_blocked_reason")) ||
      admission_or_resource_reason?(workflow.artifact("pause_reason"))
  end

  def self.admission_or_resource_reason?(reason)
    reason = reason.to_s
    reason == StepDispatcher::ADMISSION_BLOCK_REASON ||
      reason == "admission_control" ||
      reason == StepDispatcher::PAUSE_REASON_RESOURCE_SAFETY ||
      (LandingQueueReentry.landing_start_blocker?(reason) && reason.include?("workflow admission budget"))
  end

  def self.sleeper_scope
    ARTIFACT_PATTERNS.reduce(Workflow.where(state: %w[queued running]).none) do |scope, pattern|
      scope.or(Workflow.where(state: %w[queued running]).where("artifacts LIKE ?", pattern))
    end
  end

  def initialize(limit: DEFAULT_LIMIT)
    @limit = limit
  end

  def call
    workflow_ids = deferred_workflow_ids
    workflow_ids.each { |workflow_id| WorkflowPhaseAdmissionJob.perform_later(workflow_id) }
    LandingQueueProcessorJob.perform_later if workflow_ids.any?
    Result.new(workflow_ids: workflow_ids)
  end

  private

  attr_reader :limit

  def deferred_workflow_ids
    ids = []
    self.class.sleeper_scope.reorder(:id).find_each do |workflow|
      next unless self.class.admission_or_resource_paused?(workflow)

      ids << workflow.id
      break if ids.size >= limit
    end
    ids
  end
end
