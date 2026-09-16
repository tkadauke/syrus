module MetricsDashboard
  extend Syrus::PluginApi

  # How often a sample actually lands, which is not the same as `tick_interval`
  # below: PluginTickSchedulerJob polls on its own cadence, so a 1-minute tick
  # arrives roughly every 89 seconds in practice. DashboardPayload sizes its
  # buckets against this -- anything finer misses samples routinely and draws
  # the gaps as holes in the line.
  SAMPLE_INTERVAL = 90.seconds

  syrus_plugin "metrics_dashboard" do
    display_name "Metrics Dashboard"
    description "Charts Syrus's own metrics -- queue health, throughput, feature usage -- without needing Prometheus."
    long_description "Metrics Dashboard records the metrics Syrus already exposes on /metrics and charts them in the app, so a single-host install gets operational history with no extra infrastructure to run.\n\nIt reads the same data an external Prometheus would scrape, which means the built-in charts and a Grafana dashboard cannot disagree. It is deliberately not a query builder: it answers a fixed set of questions -- is the queue keeping up, what is landing, which features are used -- and an install that outgrows it can point real Prometheus at the same endpoint and turn this off.\n\nRecording stops when the plugin is disabled."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/metrics_dashboard.svg"
    author "Thomas Kadauke"
    category "observability"
    default_enabled false
    disableable true

    provides sidebar_page: "MetricsDashboard::SidebarPages",
             callbacks: "MetricsDashboard::Callbacks",
             retention_policy: "MetricsDashboard::RetentionPolicy"

    # PluginTickSchedulerJob only ticks enabled, healthy plugins, so recording
    # stops when the plugin is disabled without any flag of our own to keep in
    # sync. A disabled plugin that kept writing rollup rows would be a plugin
    # you cannot actually turn off.
    tick_interval 1.minute

    route :get, "/api/v1/app/metrics_dashboard", to: "api/v1/app/metrics_dashboard#show"

    frontend routes: {
          "metrics_dashboard/MetricsDashboard" => "app/frontend/routes/MetricsDashboard.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/metrics_dashboard.json" ]

    # The rows need no teardown declared here: metrics_dashboard_samples carries
    # the plugin's name, so Syrus::PluginPurge finds and drops the table when the
    # plugin is uninstalled.
  end
end
