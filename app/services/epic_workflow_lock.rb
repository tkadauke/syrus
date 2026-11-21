class EpicWorkflowLock
  BLOCK_REASON = "epic_wide_workflow_active".freeze

  def self.epic_for(workflow) = new(workflow).epic
  def self.active_epic_wide_workflows_for(workflow) = new(workflow).active_epic_wide_workflows
  def self.blocking_workflow_for(workflow) = new(workflow).blocking_workflow
  def self.running_member_workflow_for(workflow) = new(workflow).running_member_workflow
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

  # The other half of Epic exclusivity: an Epic-wide Workflow waits until no
  # member Workflow in its Epic is *running* (members already wait while
  # Epic-wide work is queued or running). Only running ones: a member that is
  # merely queued is itself waiting for this Workflow, and waiting on it
  # would deadlock. Neither side preempts the other.
  def running_member_workflow
    return nil unless epic && workflow.epic_wide?

    Workflow.joins(:job)
      .where(jobs: { epic_id: epic.id }, state: "running")
      .where.not(id: workflow.id)
      .where.not(trigger_kind: WorkDefinitions.epic_wide_kinds)
      .order(:created_at, :id)
      .first
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
      (epic_units - [ keeper ]).filter_map do |unit|
        next unless conflicts_with_keeper?(unit, keeper)

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

    # A second Epic-wide Workflow is always a conflict: the dispatcher cancels
    # one that cannot start. A member is only when it runs alongside a running
    # keeper. A queued member is waiting for the keeper, and a queued keeper is
    # waiting for the running member (StepDispatcher's two Epic start blocks);
    # cancelling either undid the wait and the member was relaunched into the
    # same cancellation.
    def conflicts_with_keeper?(unit, keeper)
      return true if epic_wide?(unit)

      unit.workflow&.running? && keeper.workflow&.running?
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
