module WorkUnits
  class TerminalWorkflowSync
    def self.call(workflow) = new(workflow).call
    def self.for_job(job)
      return unless job

      job.workflows.terminal.includes(:work_unit).find_each do |workflow|
        call(workflow)
      end
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
      return unless workflow&.terminal?
      return unless WorkUnit::TERMINAL_STATES.include?(workflow.state)
      return unless workflow.work_unit&.active?

      workflow.work_unit.mark_terminal!(workflow.state)
    end

    private

    attr_reader :workflow
  end
end
