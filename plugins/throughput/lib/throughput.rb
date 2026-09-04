
module Throughput
  extend Syrus::PluginApi

  syrus_plugin "throughput" do
    display_name "Throughput"
    category     "observability"
    author       "Thomas Kadauke"
    icon_url     "/plugin-icons/throughput.svg"

    description "Delivery throughput, landing waste, and review-funnel latency metrics on the repository page."
    long_description "Throughput measures how work actually moves through a repository: PR creation by source, commits and lines produced, landing attempts and their waste, and the latency of each step from PR open to merge.\n\nEvery figure carries a sample count and a confidence rating, so a number computed from three data points is not mistaken for a trend. Use it to find where delivery is stalling rather than to grade people."

    provides ui_slot: "Throughput::UiSlots"

    route :get, "/api/v1/app/repositories/:repository_id/throughput_metrics",
          to: "api/v1/app/repository_throughput#show"

    frontend ui_slots: { "throughput/ThroughputPanel" => "app/frontend/ui_slots/ThroughputPanel.tsx" }
  end
end
