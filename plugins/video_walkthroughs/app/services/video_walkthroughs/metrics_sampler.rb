module VideoWalkthroughs
  # A cache-mediated gauge for the total bytes PruneJob's size sweep is
  # weighing against AppSetting.video_storage_budget_bytes.
  #
  # PruneJob runs on a worker's `cleanup` queue, but /metrics is served by the
  # web role only (config/syrus_docs/metrics.md, "Scope") -- a Gauge#set call
  # made from inside PruneJob would sit invisible in that worker's own
  # registry forever. So PruneJob's size sweep -- which already computes this
  # exact total to decide whether to evict -- writes it here instead of
  # setting the live gauge directly, and #refresh_gauges!, called from
  # Callbacks#on_metrics_scrape on the /metrics scrape path, reads it back.
  #
  # No separate sampling cadence: PruneJob's own daily tick is this metric's
  # only sample point, since nothing evicts (or needs re-measuring) faster
  # than that job runs anyway.
  class MetricsSampler
    CACHE_KEY = "video_walkthroughs:metrics:storage_bytes".freeze
    # A little over a day, so one slow tick does not blank the gauge before
    # the next one lands.
    CACHE_TTL = 25.hours

    def self.record_storage_bytes!(bytes)
      Rails.cache.write(CACHE_KEY, bytes.to_i, expires_in: CACHE_TTL)
    end

    def self.refresh_gauges!
      bytes = Rails.cache.read(CACHE_KEY)
      return false if bytes.nil?

      Syrus::Metrics.gauge(:syrus_video_walkthroughs_storage_bytes).set(bytes)
      true
    end
  end
end
