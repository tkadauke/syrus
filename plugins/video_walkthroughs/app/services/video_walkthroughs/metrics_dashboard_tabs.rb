module VideoWalkthroughs
  # Contributes this plugin's own dashboard tab to metrics_dashboard's hosted
  # "metrics_dashboard:tab" point (see MetricsDashboard::Tab). Duck-typed --
  # this class does not include a MetricsDashboard constant, so
  # video_walkthroughs keeps working with metrics_dashboard uninstalled or
  # disabled.
  class MetricsDashboardTabs
    def self.metrics_dashboard_tabs
      [
        {
          id: "video_walkthroughs",
          label: "Walkthrough Videos",
          panels: [
            { key: "storage_bytes", metric: "syrus_video_walkthroughs_storage_bytes",
              group_by: nil, mode: :value, unit: "bytes", label: "Stored video bytes" }
          ]
        }
      ]
    end
  end
end
