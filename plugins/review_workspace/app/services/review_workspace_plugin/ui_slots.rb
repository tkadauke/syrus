module ReviewWorkspacePlugin
  class UiSlots
    include Syrus::Plugin::UiSlot

    def self.ui_slots(slot:, context:)
      return [] unless slot == "dashboard.jobs.notice"
      return [] unless context[:subject] == "job"

      count = EligibleJobs.call(user: context.fetch(:user), scope: context.fetch(:accessible_jobs_scope)).length
      return [] if count.zero?

      [
        {
          id: "review_workspace.ready_jobs",
          component: "review_workspace/ReviewDashboardNotice",
          order: 20,
          cacheable: false,
          props: { count: count }
        }
      ]
    end
  end
end
