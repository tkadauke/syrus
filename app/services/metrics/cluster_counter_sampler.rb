module Metrics
  # Brings cluster counter totals (Metrics::ClusterCounters) into the process
  # that serves /metrics. The tick reads the table into the cache; the scrape
  # reconciles each series up to its cluster total -- never down, so a
  # process's own not-yet-flushed increments cannot make a series appear to
  # shrink.
  class ClusterCounterSampler
    CACHE_KEY = "syrus:metrics:cluster_counter_totals".freeze
    CACHE_TTL = 5.minutes

    def self.sample!
      totals = ClusterCounters.totals
      Rails.cache.write(CACHE_KEY, totals, expires_in: CACHE_TTL)
      totals
    end

    def self.refresh_gauges!
      totals = Rails.cache.read(CACHE_KEY)
      return false unless totals

      totals.each do |name, series|
        definition = Syrus::Metrics.definitions.find { |candidate| candidate.name.to_s == name.to_s }
        next unless definition&.cluster

        series.each { |labels, total| Syrus::Metrics.counter(definition.name).reconcile!(total, tags: labels) }
      end
      true
    end

    Syrus::Metrics.register_sampler(self)
  end
end
