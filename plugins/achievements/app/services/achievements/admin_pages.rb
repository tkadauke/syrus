module Achievements
  # Contributes the workbench's navigation entry. Offered only while the
  # workbench is available, so disabling syrus_dev removes the entry without
  # touching normal achievement behavior.
  class AdminPages
    include Syrus::Host::AdminPage

    def self.admin_pages
      return [] unless Achievements::Workbench.available?

      [
        {
          id: "achievements.workbench",
          label: "Achievements Workbench",
          label_key: "achievements:nav_workbench",
          path: Achievements::Workbench::PAGE_PATH,
          paths: [ Achievements::Workbench::PAGE_PATH ],
          component: "achievements/AchievementsWorkbench",
          group_id: "system",
          order: 93
        }
      ]
    end
  end
end
