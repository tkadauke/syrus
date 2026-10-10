module WorkUnits
  class TerminalWorkflowSync
    ACTIVE_WORKFLOW_STATES = %w[queued running].freeze
    TERMINAL_WORK_UNIT_STATES = %w[succeeded failed cancelled].freeze
    TerminalOwnership = Data.define(:workflow, :work_unit)

    def self.call(workflow) = new(workflow).call
    def self.for_job(job)
      return unless job

      job.workflows.terminal.includes(:work_unit).find_each do |workflow|
        call(workflow)
      end
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

    def call
      return unless workflow

      if workflow.terminal?
        sync_work_unit_from_terminal_workflow
      elsif ACTIVE_WORKFLOW_STATES.include?(workflow.state)
        sync_workflow_from_terminal_work_unit
      end
    end

    private

    attr_reader :workflow

    def sync_work_unit_from_terminal_workflow
      return unless workflow.work_unit&.active?

      workflow.work_unit.mark_terminal!(workflow.state)
    end

    def sync_workflow_from_terminal_work_unit
      unit = terminal_work_unit
      return unless unit

      workflow.with_lock do
        workflow.reload
        return unless ACTIVE_WORKFLOW_STATES.include?(workflow.state)
        return if self.class.active_replacement_owns?(workflow, stale_unit: unit)

        case unit.state
        when "cancelled"
          WorkUnits::WorkflowCancellation.cancel!(
            workflow,
            reason: "terminal_work_unit",
            artifacts: { "cancelled_reason" => "terminal_work_unit" }
          )
        when "failed"
          workflow.fail! if workflow.may_fail?
          workflow.save!
        when "succeeded"
          workflow.start! if workflow.queued? && workflow.may_start?
          workflow.succeed! if workflow.may_succeed?
          workflow.save!
        end
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
