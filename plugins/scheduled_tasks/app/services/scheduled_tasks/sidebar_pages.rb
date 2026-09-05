module ScheduledTasks
  # The pages this plugin owns. They were entries in core's React route table
  # and in config/routes.rb; both named components core no longer ships.
  class SidebarPages
    include Syrus::Plugin::SidebarPage

    COMPONENT = "scheduled_tasks/ScheduledTasksPage".freeze

    def self.sidebar_pages
      [
        {
          id: "scheduled_tasks.index",
          label: "Schedules",
          label_key: "nav:schedules",
          path: "/scheduled_tasks",
          paths: [
            "/scheduled_tasks",
            "/scheduled_tasks/new",
            "/scheduled_tasks/:id",
            "/scheduled_tasks/:id/edit",
            "/repositories/:repository_id/scheduled_tasks",
            "/repositories/:repository_id/scheduled_tasks/new"
          ],
          component: COMPONENT,
          section: "primary",
          order: 30
        },
        {
          id: "scheduled_tasks.cron_templates",
          label: "Schedule templates",
          path: "/cron_templates",
          paths: [
            "/cron_templates",
            "/cron_templates/new",
            "/cron_templates/:id",
            "/cron_templates/:id/edit"
          ],
          component: COMPONENT,
          section: "settings",
          order: 101
        }
      ]
    end
  end
end
