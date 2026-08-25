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
    work_unit_sleeper_scope.exists? || legacy_sleeper_scope.exists?
  end

  def self.admission_or_resource_paused?(workflow)
    admission_or_resource_reason?(WorkUnits::StartBlock.for(workflow).reason) ||
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

  def self.sleeper_workflows
    work_unit_workflows = work_unit_sleeper_scope.includes(:workflow).order(:id).map(&:workflow)
    legacy_workflows = legacy_sleeper_scope.to_a.select { |workflow| admission_or_resource_paused?(workflow) }
    (work_unit_workflows + legacy_workflows).uniq(&:id)
  end

  def self.legacy_sleeper_scope
    WorkUnits::Ownership.legacy_replay_workflows_scope(nil, base_scope: sleeper_scope)
  end

  def self.work_unit_sleeper_scope
    WorkUnit
      .joins(:workflow)
      .where(state: "blocked", blocked_reason: %w[admission_control resource_safety])
      .where(workflows: { state: %w[queued running] })
  end

  def initialize(limit: DEFAULT_LIMIT)
    @limit = limit
  end

  def call
    workflow_ids = deferred_workflow_ids
    workflow_ids.each { |workflow_id| WorkflowPhaseAdmissionJob.enqueue_once(workflow_id) }
    LandingQueueProcessorJob.perform_later if workflow_ids.any?
    Result.new(workflow_ids: workflow_ids)
  end

  private

  attr_reader :limit

  def deferred_workflow_ids
    self.class.sleeper_workflows.first(limit).map(&:id)
  end
end
