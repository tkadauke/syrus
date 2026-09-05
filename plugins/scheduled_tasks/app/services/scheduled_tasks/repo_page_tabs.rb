module ScheduledTasks
  # The repository "Scheduled Tasks" tab.
  #
  # Core used to append this itself, complete with the simple-mode rule, which
  # meant naming a plugin's surface and its route helper. The plugin decides
  # whether its own tab appears.
  class RepoPageTabs
    include Syrus::Plugin::RepoPageTab

    def self.repo_page_tabs(repository:, user: nil)
      return [] if repository.blank?
      # Simple mode hides developer surfaces; schedules are one of them.
      return [] if AppSetting.simple?

      path = "/repositories/#{repository.id}/scheduled_tasks"
      [
        {
          id: "scheduled_tasks.repository",
          label: "Scheduled Tasks",
          path: path,
          paths: [ path, "#{path}/new" ],
          component: SidebarPages::COMPONENT,
          order: 6
        }
      ]
    end
  end
end
