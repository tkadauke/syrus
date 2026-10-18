module MetricsDashboard
  # Records the current /metrics output into rollup rows, once a minute.
  #
  # It consumes the exposition text rather than the registry, so the built-in
  # charts and an external Prometheus read the same source and cannot disagree
  # (see TextFormatParser).
  #
  # Cluster counters are omitted when their shared snapshot is unavailable;
  # the recorder process's local zero would be a plausible-looking undercount.
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
          series_key: MetricsDashboard::Sample.series_key_for(sample.labels),
          value: sample.value,
          recorded_at: @minute
        }
      end

      MetricsDashboard::Sample.upsert_all(rows, **upsert_options)
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
      if MetricsDashboard::Sample.connection.supports_insert_conflict_target?
        options[:unique_by] = :idx_metrics_dashboard_series_minute
      end
      options
    end

    private

    # Refreshing first so the global gauges hold this minute's cached sample
    # rather than whatever this process last rendered -- otherwise a recorder
    # in a process that never serves /metrics would record zeroes forever.
    #
    # Iterates Syrus::Metrics.samplers rather than naming samplers, the same
    # registry MetricsController#refresh_global_gauges refreshes from -- so
    # adding a new core or plugin sampler requires no change here. Each
    # sampler's refresh is independently rescued so one unreachable source
    # costs its own gauges, not every other sampler's.
    def exposition
      cluster_counters_available = true
      Syrus::Metrics.samplers.each do |sampler|
        refreshed = sampler.refresh_gauges!
        cluster_counters_available = false if sampler == Metrics::ClusterCounterSampler && !refreshed
      rescue StandardError => e
        cluster_counters_available = false if sampler == Metrics::ClusterCounterSampler
        Rails.logger.warn("[MetricsDashboard::Recorder] could not refresh #{sampler}: #{e.class}: #{e.message}")
      end
      rendered = Syrus::Metrics.render
      return rendered if cluster_counters_available

      cluster_names = Syrus::Metrics.definitions.select(&:cluster).map { |definition| definition.name.to_s }
      rendered.lines.reject do |line|
        cluster_names.any? { |name| line.match?(/\A(?:# (?:HELP|TYPE) )?#{Regexp.escape(name)}(?:\{| |$)/) }
      end.join
    rescue StandardError => e
      Rails.logger.warn("[MetricsDashboard::Recorder] could not render metrics: #{e.class}: #{e.message}")
      ""
    end
  end
end
