module SpendingInsights
  # Contributes this plugin's own dashboard tab to metrics_dashboard's hosted
  # "metrics_dashboard:tab" point (see MetricsDashboard::Tab). Duck-typed --
  # this class does not include a MetricsDashboard constant, so
  # spending_insights keeps working with metrics_dashboard uninstalled or
  # disabled.
  class MetricsDashboardTabs
    def self.metrics_dashboard_tabs
      [
        {
          id: "spending_insights",
          label: "Spending Insights",
          panels: [
            { key: "run_cost_by_provider", metric: "syrus_spending_insights_run_cost_usd_total",
              group_by: "provider", mode: :rate, unit: "USD", label: "Agent spend, by provider" },
            { key: "run_cost_by_trigger_kind", metric: "syrus_spending_insights_run_cost_usd_total",
              group_by: "trigger_kind", mode: :rate, unit: "USD", label: "Agent spend, by trigger kind" }
          ]
        }
      ]
    end
  end
end
