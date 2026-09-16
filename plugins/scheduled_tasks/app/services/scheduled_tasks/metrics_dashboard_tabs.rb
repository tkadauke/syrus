module ScheduledTasks
  # Contributes this plugin's own dashboard tab to metrics_dashboard's hosted
  # "metrics_dashboard:tab" point (see MetricsDashboard::Tab). Duck-typed --
  # this class does not include a MetricsDashboard constant, so
  # scheduled_tasks keeps working with metrics_dashboard uninstalled or
  # disabled.
  class MetricsDashboardTabs
    def self.metrics_dashboard_tabs
      [
        {
          id: "scheduled_tasks",
          label: "Scheduled Tasks",
          panels: [
            { key: "autopaused", metric: "syrus_scheduled_tasks_autopaused_total",
              group_by: nil, mode: :value, unit: "tasks", label: "Auto-paused tasks" }
          ]
        }
      ]
    end
  end
end
