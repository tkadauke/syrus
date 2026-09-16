module Throughput
  # Contributes this plugin's own dashboard tab to metrics_dashboard's hosted
  # "metrics_dashboard:tab" point (see MetricsDashboard::Tab). Duck-typed --
  # this class does not include a MetricsDashboard constant, so throughput
  # keeps working with metrics_dashboard uninstalled or disabled.
  class MetricsDashboardTabs
    def self.metrics_dashboard_tabs
      [
        {
          id: "throughput",
          label: "Throughput",
          panels: [
            { key: "landing_units", metric: "syrus_throughput_landing_units_total",
              group_by: "unit_type", mode: :rate, unit: "units", label: "Landing units, by type" },
            { key: "throughput_jobs_landed", metric: "syrus_throughput_jobs_landed_total",
              group_by: nil, mode: :rate, unit: "jobs", label: "Jobs landed" }
          ]
        }
      ]
    end
  end
end
