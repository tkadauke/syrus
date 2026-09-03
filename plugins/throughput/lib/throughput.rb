require "throughput/version"
require "throughput/engine"

module Throughput
  def self.register!
    Syrus::PluginRegistry.register(
      name:            "throughput",
      display_name:    "Throughput",
      version:         Throughput::VERSION,
      default_enabled: true,
      disableable:     true,
      category:        "observability",
      description:     "Delivery throughput, landing waste, and review-funnel latency metrics on the repository page.",
      long_description: "Throughput measures how work actually moves through a repository: PR creation by source, commits and lines produced, landing attempts and their waste, and the latency of each step from PR open to merge.\n\nEvery figure carries a sample count and a confidence rating, so a number computed from three data points is not mistaken for a trend. Use it to find where delivery is stalling rather than to grade people.",
      homepage:        "https://github.com/tkadauke/syrus",
      icon_url:        "/plugin-icons/spqr_eagle.svg",
      author:          "Thomas Kadauke",
      frontend: {
        ui_slots: {
          "throughput/ThroughputPanel" => "app/frontend/ui_slots/ThroughputPanel.tsx"
        }
      },
      routes: [
        {
          verb: "GET",
          path: "/api/v1/app/repositories/:repository_id/throughput_metrics",
          controller: "api/v1/app/repository_throughput#show"
        }
      ],
      provides: {
        ui_slot: Throughput::UiSlots
      }
    )
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "throughput" && manifest.enabled? }
  end
end
