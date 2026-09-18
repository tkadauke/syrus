module ScheduledTasks
  # The repository "Scheduled Tasks" tab.
  #
  # Core used to append this itself, which meant naming a plugin's surface
  # and its route helper. The plugin decides whether its own tab appears.
  class RepoPageTabs
    include Syrus::Plugin::RepoPageTab

    def self.repo_page_tabs(repository:, user: nil)
      return [] if repository.blank?

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
