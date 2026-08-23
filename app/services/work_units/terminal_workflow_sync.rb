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

    def call
      return unless workflow&.terminal?
      return unless workflow.work_unit&.active?

      workflow.work_unit.mark_terminal!(workflow.state)
    end

    private

    attr_reader :workflow
  end
end
