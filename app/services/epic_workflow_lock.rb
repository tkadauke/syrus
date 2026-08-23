class EpicWorkflowLock
  BLOCK_REASON = "epic_wide_workflow_active".freeze

  def self.epic_for(workflow) = new(workflow).epic
  def self.active_epic_wide_workflows_for(workflow) = new(workflow).active_epic_wide_workflows
  def self.blocking_workflow_for(workflow) = new(workflow).blocking_workflow
  def self.conflicting_active_workflows(workflows) = ConflictDetector.new(workflows).conflicts

  def initialize(workflow)
    @workflow = workflow
  end

  def epic
    workflow.job&.epic
  end

  def active_epic_wide_workflows
    return [] unless epic

    unit_workflows = WorkUnits::Ownership
      .active_units_for_epic(epic, kinds: WorkDefinitions.epic_wide_kinds)
      .filter_map(&:workflow)
    legacy_workflows = WorkUnits::Ownership
      .legacy_active_epic_workflows(epic, kinds: WorkDefinitions.epic_wide_kinds)
      .order(:created_at, :id)
      .to_a

    (unit_workflows + legacy_workflows)
      .uniq(&:id)
      .reject { |candidate| candidate.id == workflow.id }
      .sort_by { |candidate| [ candidate.created_at || Time.zone.at(0), candidate.id || 0 ] }
  end

  def blocking_workflow
    active_epic_wide_workflows.first
  end

  private

  attr_reader :workflow

  class ConflictDetector
    def initialize(workflows)
      @workflows = Array(workflows).select { |workflow| workflow.queued? || workflow.running? }
    end

    def conflicts
      workflows.group_by { |workflow| workflow.job&.epic_id }.flat_map do |epic_id, epic_workflows|
        next [] if epic_id.blank?

        conflicts_for_epic(epic_workflows)
      end.compact
    end

    private

    attr_reader :workflows

    def conflicts_for_epic(epic_workflows)
      epic_wide = epic_workflows.select(&:epic_wide?).sort_by { |workflow| [ workflow.created_at || Time.zone.at(0), workflow.id || 0 ] }
      return [] if epic_wide.empty?

      keeper = epic_wide.first
      (epic_workflows - [ keeper ]).map do |workflow|
        {
          workflow: workflow,
          keeper: keeper,
          reason: workflow.epic_wide? ? "another Epic-wide workflow is already active" : "an Epic-wide workflow is active"
        }
      end
    end
  end
end
