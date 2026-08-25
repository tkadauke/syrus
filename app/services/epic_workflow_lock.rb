class EpicWorkflowLock
  BLOCK_REASON = "epic_wide_workflow_active".freeze

  def self.epic_for(workflow) = new(workflow).epic
  def self.active_epic_wide_workflows_for(workflow) = new(workflow).active_epic_wide_workflows
  def self.blocking_workflow_for(workflow) = new(workflow).blocking_workflow
  def self.conflicting_active_units(units) = ConflictDetector.new(units).conflicts

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
      .select { |candidate| candidate.queued? || candidate.running? }
    sorted_candidates(unit_workflows)
  end

  def blocking_workflow
    active_epic_wide_workflows.first
  end

  private

  attr_reader :workflow

  def sorted_candidates(candidates)
    candidates
      .uniq(&:id)
      .reject { |candidate| candidate.id == workflow.id }
      .sort_by { |candidate| [ candidate.created_at || Time.zone.at(0), candidate.id || 0 ] }
  end

  class ConflictDetector
    def initialize(units)
      @units = Array(units).select { |unit| unit.active? && active_workflow?(unit.workflow) }
    end

    def conflicts
      units_by_epic.flat_map do |epic_id, epic_units|
        next [] if epic_id.blank?

        conflicts_for_epic(epic_units)
      end.compact
    end

    private

    attr_reader :units

    def units_by_epic
      units.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |unit, grouped|
        epic_ids_for(unit).each { |epic_id| grouped[epic_id] << unit }
      end
    end

    def conflicts_for_epic(epic_units)
      epic_wide = epic_units.select { |unit| epic_wide?(unit) }.sort_by { |unit| [ unit.created_at || Time.zone.at(0), unit.id || 0 ] }
      return [] if epic_wide.empty?

      keeper = epic_wide.first
      (epic_units - [ keeper ]).map do |unit|
        workflow = unit.workflow
        {
          workflow: workflow,
          keeper: keeper.workflow,
          work_unit: unit,
          keeper_work_unit: keeper,
          reason: epic_wide?(unit) ? "another Epic-wide workflow is already active" : "an Epic-wide workflow is active"
        }
      end
    end

    def active_workflow?(workflow)
      workflow&.queued? || workflow&.running?
    end

    def epic_wide?(unit)
      WorkDefinitions.epic_wide_kinds.include?(unit.kind)
    end

    def epic_ids_for(unit)
      ids = []
      ids << unit.scope_id if unit.scope_type == "epic"
      ids << unit.workflow&.job&.epic_id
      ids.concat(unit.work_unit_members.map { |member| member.job&.epic_id })
      ids.compact.uniq
    end
  end
end
