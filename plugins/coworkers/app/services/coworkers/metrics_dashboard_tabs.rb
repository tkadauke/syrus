module Coworkers
  class MetricsDashboardTabs
    def self.metrics_dashboard_tabs
      [ {
        id: "coworkers", label: "Coworkers", panels: [
          { key: "coworkers_journaling_age", metric: "syrus_coworkers_journaling_last_result_age_seconds", group_by: "coworker", mode: :value, unit: "seconds", label: "Last journaling result age" },
          { key: "coworkers_unsaved_age", metric: "syrus_coworkers_unsaved_workspace_age_seconds", group_by: "coworker", mode: :value, unit: "seconds", label: "Unsaved workspace age" },
          { key: "coworkers_spend", metric: "syrus_coworkers_spend_usd_total", group_by: "coworker", mode: :rate, unit: "USD", label: "Coworker spend" }
        ], summary: Coworkers::MetricsDashboardSummary.build
      } ]
    end
  end
end
