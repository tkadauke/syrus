module Throughput
  # Drives the global landing-throughput metrics sample cycle. See
  # MetricsSampler for why this needs its own tick and cache-mediated
  # counters instead of incrementing at the landing call site directly.
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      MetricsSampler.sample!
    rescue StandardError => e
      Rails.logger.warn("[Throughput] tick failed: #{e.class}: #{e.message}")
    end

    def self.on_metrics_scrape
      MetricsSampler.refresh_gauges!
    end
  end
end
