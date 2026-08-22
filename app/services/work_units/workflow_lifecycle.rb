module WorkUnits
  class WorkflowLifecycle
    def self.started!(workflow)
      new(workflow).started!
    end

    def self.terminal!(workflow, state:)
      new(workflow).terminal!(state: state)
    end

    def initialize(workflow)
      @workflow = workflow
    end

    def started!
      work_unit&.mark_running!
    end

    def terminal!(state:)
      work_unit&.mark_terminal!(state)
    end

    private

    attr_reader :workflow

    def work_unit
      workflow.work_unit
    end
  end
end
