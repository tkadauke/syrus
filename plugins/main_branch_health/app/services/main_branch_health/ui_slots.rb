module MainBranchHealth
  class UiSlots
    include Syrus::Plugin::UiSlot

    def self.ui_slots(slot:, context:)
      return [] unless slot == "repository.settings"

      [
        {
          id: "main_branch_health.repository_settings",
          component: "main_branch_health/RepositorySettings",
          order: 10,
          cacheable: false
        }
      ]
    end
  end
end
