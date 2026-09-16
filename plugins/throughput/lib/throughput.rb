
module Throughput
  extend Syrus::PluginApi

  syrus_plugin "throughput" do
    display_name "Throughput"
    category     "observability"
    author       "Thomas Kadauke"
    icon_url     "/plugin-icons/throughput.svg"

    description "Delivery throughput, landing waste, and review-funnel latency metrics on the repository page."
    long_description "Throughput measures how work actually moves through a repository: PR creation by source, commits and lines produced, landing attempts and their waste, and the latency of each step from PR open to merge.\n\nEvery figure carries a sample count and a confidence rating, so a number computed from three data points is not mistaken for a trend. Use it to find where delivery is stalling rather than to grade people."

    # Sample cadence for MetricsSampler -- same order of magnitude as core's
    # own SampleGlobalMetricsJob tick.
    tick_interval 1.minute

    provides ui_slot: "Throughput::UiSlots",
             callbacks: "Throughput::Callbacks"

    route :get, "/api/v1/app/repositories/:repository_id/throughput_metrics",
          to: "api/v1/app/repository_throughput#show"
    route :get, "/api/v1/admin/throughput", to: "api/v1/admin/throughput#show"

    frontend ui_slots: { "throughput/ThroughputPanel" => "app/frontend/ui_slots/ThroughputPanel.tsx" },
             i18n: [ "app/frontend/i18n/locales/*/throughput.json" ]

    # NOT Throughput::MetricContract (see MetricsSampler's doc) -- that's a
    # per-repository, request-computed API contract. These are global,
    # cache-mediated counters sampled on this plugin's own tick.
    metrics do
      counter :landing_units_total, tags: %i[unit_type],
              comment: "Successful landing attempts (one auto_merge Workflow or one merge_train counts as one unit)"
      counter :jobs_landed_total,
              comment: "Jobs landed via a successful landing attempt (a merge_train counts every member Job)"
    end
  end
end
