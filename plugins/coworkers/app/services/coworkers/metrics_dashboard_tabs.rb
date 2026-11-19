module Coworkers
  class MetricsDashboardTabs
    def self.metrics_dashboard_tabs
      [ {
        id: "coworkers", label: I18n.t("api.coworkers.metrics_dashboard.tab"),
        summary: Coworkers::MetricsDashboardSummary.build,
        panels: [
          { key: "coworkers_journaling_age", metric: "syrus_coworkers_journaling_last_result_age_seconds", group_by: "coworker", mode: :value, unit: "seconds", label: I18n.t("api.coworkers.metrics_dashboard.charts.journaling_age") },
          { key: "coworkers_unsaved_age", metric: "syrus_coworkers_unsaved_workspace_age_seconds", group_by: "coworker", mode: :value, unit: "seconds", label: I18n.t("api.coworkers.metrics_dashboard.charts.unsaved_age") },
          { key: "coworkers_spend", metric: "syrus_coworkers_spend_usd_total", group_by: "coworker", mode: :rate, unit: "USD", label: I18n.t("api.coworkers.metrics_dashboard.charts.spend") }
        ]
      } ]
    end
  end
end
