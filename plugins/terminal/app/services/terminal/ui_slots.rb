module Terminal
  module UiSlots
    def self.ui_slots(slot:, context:)
      return [] unless slot == "job.workflow.actions"
      job = context[:job]
      return [] unless job

      [
        {
          id: "terminal.open_workspace",
          component: "terminal/OpenWorkspaceButton",
          order: 10,
          props: {
            availability_by_workflow_id: Terminal::WorkspaceAvailability.by_workflow_id(job.workflows.to_a)
          }
        }
      ]
    end
  end
end
