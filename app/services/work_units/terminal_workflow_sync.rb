module WorkUnits
  class TerminalWorkflowSync
    ACTIVE_WORKFLOW_STATES = %w[queued running].freeze
    TERMINAL_WORK_UNIT_STATES = %w[succeeded failed cancelled].freeze
    TerminalOwnership = Data.define(:workflow, :work_unit)

    def self.call(workflow) = new(workflow).call
    def self.for_job(job)
      return false unless job

      changed = false

      job.workflows.terminal.includes(:work_unit).find_each do |workflow|
        changed = call(workflow) || changed
      end

      return changed if job.closed?

      terminal_work_unit_owned_active_workflows_for_job(job).each do |ownership|
        changed = call(ownership.workflow) || changed
      end

      changed
    end

    def self.terminal_work_unit_owned_active_workflows_for_job(job)
      return [] unless job

      WorkUnit
        .joins(:work_unit_members, :workflow)
        .includes(:workflow)
        .where(work_unit_members: { job_id: job.id })
        .where(state: TERMINAL_WORK_UNIT_STATES)
        .where(workflows: { state: ACTIVE_WORKFLOW_STATES })
        .order(:created_at, :id)
        .filter_map do |unit|
          workflow = unit.workflow
          next if active_replacement_owns?(workflow, stale_unit: unit)

          TerminalOwnership.new(workflow: workflow, work_unit: unit)
        end
    end

    def self.active_replacement_owns?(workflow, stale_unit:)
      return false unless workflow && stale_unit

      WorkUnit
        .where(workflow_id: workflow.id, state: Ownership::ACTIVE_STATES)
        .where.not(id: stale_unit.id)
        .exists?
    end

    def initialize(workflow)
      @workflow = workflow
    end

    # Workflow#terminal? and Workflow.terminal both count `blocked`, but a
    # WorkUnit has no blocked *outcome* -- blocked there is an active state
    # meaning "waiting on something external". Passing a blocked Workflow's
    # state to mark_terminal! raised ArgumentError, and because this runs
    # inside WorkEngine::Reconciler#classify_superseded_active_runtime_work it
    # took the entire reconciler pass down with it: no stale-run reaping, no
    # landing repairs, nothing self-healing, for as long as one blocked
    # Workflow with an active WorkUnit existed. Three of them wedged
    # production for well over an hour.
    def call
      return false unless workflow

      if workflow.terminal?
        sync_work_unit_from_terminal_workflow
      elsif ACTIVE_WORKFLOW_STATES.include?(workflow.state)
        sync_workflow_from_terminal_work_unit
      else
        false
      end
    end

    private

    attr_reader :workflow

    def sync_work_unit_from_terminal_workflow
      return false unless workflow.work_unit&.active?

      if WorkUnit::TERMINAL_STATES.include?(workflow.state)
        workflow.work_unit.mark_terminal!(workflow.state)
        true
      elsif workflow.blocked? && Workflow::TriggerKind.implemented_state_compatible?(workflow.trigger_kind)
        # Repairs a blocked auxiliary Workflow whose WorkUnit stayed active.
        workflow.work_unit.mark_terminal!("failed")
        true
      else
        false
      end
    end

    def sync_workflow_from_terminal_work_unit
      unit = terminal_work_unit
      return false unless unit

      # Driving the Workflow rolls up to its WorkUnit, intent and Job, so its
      # ancestry is locked first, top down (NY40), then both are reloaded as
      # lock! would.
      Workflow.transaction do
        Lineage.lock!(workflow)
        workflow.job&.reload
        workflow.reload
        return false unless ACTIVE_WORKFLOW_STATES.include?(workflow.state)
        return false if self.class.active_replacement_owns?(workflow, stale_unit: unit)

        case unit.state
        when "cancelled"
          WorkUnits::WorkflowCancellation.cancel!(
            workflow,
            reason: "terminal_work_unit",
            artifacts: { "cancelled_reason" => "terminal_work_unit" }
          )
        when "failed"
          workflow.finished_at = Time.current
          workflow.fail! if workflow.may_fail?
        when "succeeded"
          if workflow.queued? && workflow.may_start?
            workflow.syncing_from_terminal_work_unit = true
            workflow.started_at = Time.current
            workflow.start!
          end
          workflow.finished_at = Time.current
          workflow.succeed! if workflow.may_succeed?
        end

        true
      ensure
        workflow.syncing_from_terminal_work_unit = false
      end
    end

    def terminal_work_unit
      WorkUnit
        .where(workflow_id: workflow.id, state: TERMINAL_WORK_UNIT_STATES)
        .order(created_at: :desc, id: :desc)
        .detect { |unit| !self.class.active_replacement_owns?(workflow, stale_unit: unit) }
    end
  end
end
