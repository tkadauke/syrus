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
      unit = work_unit
      return if unit.nil?
      # A Workflow can be driven through `start!` purely to reach a terminal
      # state from :queued -- WorkUnits::TerminalWorkflowSync does exactly that
      # when it finds a succeeded WorkUnit behind a still-queued Workflow, and
      # AASM has no queued -> succeeded edge.
      #
      # Marking an already-terminal unit running during that synchronization is
      # wrong on its own terms, and it is not harmless: mark_running! reclaims
      # the unit's active dedup slot, so if a sibling unit for the same job and
      # kind holds it, the UNIQUE index on active_dedup_key raises
      # RecordNotUnique. A normal retry does need to reactivate the same unit,
      # so only the terminal synchronization path opts out.
      return if unit.terminal? && workflow.syncing_from_terminal_work_unit

      unit.mark_running!
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
