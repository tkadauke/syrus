module MetricsDashboard
  # Records the current /metrics output into rollup rows, once a minute.
  #
  # It consumes the exposition text rather than the registry, so the built-in
  # charts and an external Prometheus read the same source and cannot disagree
  # (see TextFormatParser).
  #
  # **What it can and cannot see, stated plainly.** The recorder runs inside one
  # process and renders that process's registry, after refreshing the global
  # gauges from the cache. So:
  #
  #   * `syrus_global_*` -- accurate. They are sampled cluster-wide into the
  #     cache by SampleGlobalMetricsJob and are the same everywhere.
  #   * per-process counters (feature usage) -- only this process's share.
  #     Counters incremented on web are not visible to a worker, because worker
  #     pods are not scraped yet and processes share no memory.
  #
  # That gap is the unbuilt cross-process capture noted in
  # docs/plans/prometheus-dashboard.md, not something this plugin works around.
  # When it lands, these panels gain the data with no change here.
  class Recorder
    class << self
      def record!(...) = new(...).record!
    end

    def initialize(now: Time.current)
      # Truncated to the minute, which is what makes the recording idempotent:
      # two ticks in the same minute update one row rather than creating two.
      @minute = now.change(sec: 0, usec: 0)
    end

    def record!
      samples = TextFormatParser.parse(exposition)
      return 0 if samples.empty?

      rows = samples.map do |sample|
        {
          metric: sample.metric,
          labels: sample.labels,
          series_key: MetricsDashboardSample.series_key_for(sample.labels),
          value: sample.value,
          recorded_at: @minute
        }
      end

      MetricsDashboardSample.upsert_all(rows, **upsert_options)
      rows.size
    end

    # MySQL rejects `unique_by` outright -- ON DUPLICATE KEY UPDATE fires on any
    # unique index, so there is no conflict target to name -- while SQLite and
    # Postgres need one, or they conflict on the primary key and insert
    # duplicates instead of updating the minute's row.
    #
    # Dev and test run SQLite and production runs MySQL, so passing it
    # unconditionally passed every spec and could never have worked in
    # production. `supports_insert_conflict_target?` is the same predicate
    # ActiveRecord::InsertAll checks before raising.
    def upsert_options
      options = { update_only: %i[value labels] }
      if MetricsDashboardSample.connection.supports_insert_conflict_target?
        options[:unique_by] = :idx_metrics_dashboard_series_minute
      end
      options
    end

    private

    # Refreshing first so the global gauges hold this minute's cached sample
    # rather than whatever this process last rendered -- otherwise a recorder
    # in a process that never serves /metrics would record zeroes forever.
    def exposition
      Metrics::QueueSampler.refresh_gauges!
      Metrics::PluginSampler.refresh_gauges!
      Syrus::Metrics.render
    rescue StandardError => e
      Rails.logger.warn("[MetricsDashboard::Recorder] could not render metrics: #{e.class}: #{e.message}")
      ""
    end
  end
end
