module SpendingInsights
  # Drives the plugin's own metrics sample cycle. See MetricsSampler for why
  # this needs a tick at all instead of incrementing the counter directly at
  # the point Run#cost_usd is recorded.
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      MetricsSampler.sample!
    rescue StandardError => e
      Rails.logger.warn("[SpendingInsights] tick failed: #{e.class}: #{e.message}")
    end

    def self.on_metrics_scrape
      MetricsSampler.refresh_gauges!
    end
  end
end
