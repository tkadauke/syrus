module Terminal
  module UiSlots
    def self.ui_slots(slot:, context:)
      return [] unless slot == "job.workflow.actions"
      return [] unless context[:job]

      [ { id: "terminal.open_workspace", component: "terminal/OpenWorkspaceButton", order: 10 } ]
    end
  end
end
