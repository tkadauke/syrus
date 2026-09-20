
module Throughput
  extend Syrus::PluginApi

  syrus_plugin "throughput" do
    display_name "Throughput"
    category     "observability"
    author       "Thomas Kadauke"
    icon_url     "/plugin-icons/throughput.svg"

    description "Delivery throughput, landing waste, and review-funnel latency metrics on the repository page."
    long_description "Throughput measures how work actually moves through a repository: PR creation by source, commits and lines produced, landing attempts and their waste, and the latency of each step from PR open to merge.\n\nEvery figure carries a sample count and a confidence rating, so a number computed from three data points is not mistaken for a trend. Use it to find where delivery is stalling rather than to grade people."

    optionally_depends_on [ "metrics_dashboard" ]
    provides repo_page_tab: "Throughput::RepoPageTabs",
             "metrics_dashboard:tab" => "Throughput::MetricsDashboardTabs"

    route :get, "/api/v1/app/repositories/:repository_id/throughput_metrics",
          to: "api/v1/app/repository_throughput#show"
    route :get, "/api/v1/admin/throughput", to: "api/v1/admin/throughput#show"

    frontend routes: { "throughput/RepositoryThroughput" => "app/frontend/repo_tabs/RepositoryThroughput.tsx" },
             i18n: [ "app/frontend/i18n/locales/*/throughput.json" ]

    # NOT Throughput::MetricContract (see MetricsSampler's doc) -- that's a
    # per-repository, request-computed API contract. These are global,
    # cache-mediated counters. MetricsSampler needs cursor-based cumulative
    # logic (see its class doc), so it registers as a full sampler class via
    # `sampler` -- the same Syrus::Metrics sampler registry a declarative
    # `gauge` block uses, sampled on the shared control-plane tick with no
    # plugin-owned tick_interval/on_tick.
    metrics do
      counter :landing_units_total, tags: %i[unit_type],
              comment: "Successful landing attempts (one auto_merge Workflow or one merge_train counts as one unit)"
      counter :jobs_landed_total,
              comment: "Jobs landed via a successful landing attempt (a merge_train counts every member Job)"
      sampler MetricsSampler
    end
  end
end
