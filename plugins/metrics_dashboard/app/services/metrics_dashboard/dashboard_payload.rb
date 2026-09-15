module MetricsDashboard
  # The fixed set of panels this plugin draws.
  #
  # Deliberately not a query builder. It answers the questions the dashboard
  # plan opened with -- is the queue keeping up, what is failing, which features
  # are used -- and nothing else. An install that needs arbitrary queries needs
  # Prometheus, and /metrics is already there for it.
  #
  # Two things here exist to make the charts readable rather than merely
  # correct:
  #
  # **One shared bucket grid.** Every panel is sampled onto the same timestamps,
  # so index i means the same instant in every chart. That is what lets the UI
  # draw one crosshair across all of them, and it is why the grid is built once
  # at payload level instead of per panel.
  #
  # **Counters are served as a rate, not a total.** A cumulative counter drawn
  # raw is a flat line at a big number -- `syrus_global_queue_failed_count` sat
  # at 3,319 all day, which says nothing about whether failures are happening
  # now. Panels declare `mode: :rate` and get the change per bucket instead,
  # which is the same thing PromQL's rate() does at query time.
  class DashboardPayload
    # Bucket sizes chosen so every window lands near 60-170 points: enough to
    # show shape, few enough that each is a visible pixel column.
    # A bucket must be comfortably wider than the recorder's effective period or
    # it cannot reliably contain a sample. The recorder declares
    # `tick_interval 1.minute`, but the plugin tick scheduler adds its own poll
    # latency on top: measured, samples actually land about every 89 seconds. A
    # 1-minute bucket therefore missed roughly one in three, and every miss drew
    # a hole in the line -- the chart reported an outage that was really jitter.
    WINDOWS = {
      "1h" => { span: 1.hour, bucket: 3.minutes },
      "6h" => { span: 6.hours, bucket: 5.minutes },
      "24h" => { span: 24.hours, bucket: 15.minutes },
      "7d" => { span: 7.days, bucket: 1.hour }
    }.freeze
    DEFAULT_WINDOW = "6h".freeze

    # `aggregate` is the honest part for gauges: syrus_global_* series are one
    # cluster-wide fact rendered identically by every recorder, so summing them
    # multiplies by the number of recorders. Max is the only correct reduction.
    PANELS = [
      { key: "queue_oldest_age", metric: "syrus_global_queue_oldest_age_seconds",
        group_by: "queue", mode: :value, aggregate: :max, unit: "seconds" },
      { key: "queue_ready", metric: "syrus_global_queue_ready_count",
        group_by: "queue", mode: :value, aggregate: :max, unit: "jobs" },
      { key: "queue_failed", metric: "syrus_global_queue_failed_count",
        group_by: "job_class", mode: :rate, unit: "new failures" },
      { key: "queue_orphaned", metric: "syrus_global_queue_orphaned_rows",
        group_by: nil, mode: :value, aggregate: :max, unit: "rows" },
      { key: "feature_usage", metric: "syrus_feature_used_total",
        group_by: "feature", mode: :rate, unit: "uses" }
    ].freeze

    # Rate panels with many series are unreadable and mostly zero; keep the ones
    # that actually moved.
    RATE_SERIES_LIMIT = 8
    # How long a gauge reading stays good for once the samples stop.
    STALENESS = 5.minutes

    def self.build(window: DEFAULT_WINDOW) = new(window: window).build

    def initialize(window: DEFAULT_WINDOW)
      @window = WINDOWS.key?(window) ? window : DEFAULT_WINDOW
    end

    def build
      {
        window: @window,
        windows: WINDOWS.keys,
        bucket_seconds: bucket.to_i,
        buckets: buckets.map(&:iso8601),
        recording: recording?,
        last_recorded_at: last_recorded_at&.iso8601,
        panels: PANELS.map { |panel| panel_for(panel) }
      }
    end

    private

    def config = WINDOWS.fetch(@window)
    def span = config[:span]
    def bucket = config[:bucket]

    # Aligned to the bucket size so the grid is stable between refreshes and
    # two loads of the same window produce the same x positions.
    def grid_end
      @grid_end ||= begin
        now = Time.current
        Time.zone.at((now.to_i / bucket.to_i) * bucket.to_i)
      end
    end

    def grid_start = grid_end - span

    def buckets
      @buckets ||= begin
        count = (span / bucket).to_i
        (0..count).map { |i| grid_start + (i * bucket) }
      end
    end

    def bucket_index_for(time)
      index = ((time - grid_start) / bucket).floor
      return nil if index.negative? || index >= buckets.size

      index
    end

    def recording? = last_recorded_at.present? && last_recorded_at > 5.minutes.ago

    def last_recorded_at
      return @last_recorded_at if defined?(@last_recorded_at)

      @last_recorded_at = MetricsDashboard::Sample.maximum(:recorded_at)
    end

    def panel_for(panel)
      # One sample before the window too: a rate needs a predecessor to
      # difference the first bucket against, or the chart always opens with a
      # misleading zero.
      rows = MetricsDashboard::Sample
        .for_metric(panel[:metric])
        .where(recorded_at: (grid_start - bucket)..)
        .order(:recorded_at)
        .pluck(:labels, :value, :recorded_at)

      grouped = rows.group_by { |labels, _value, _at| label_of(labels, panel[:group_by]) }
      series = grouped.map { |name, points| series_for(name, points, panel) }

      {
        key: panel[:key],
        metric: panel[:metric],
        unit: panel[:unit],
        mode: panel[:mode].to_s,
        series: prune(series, panel).sort_by { |entry| entry[:name].to_s }
      }
    end

    def series_for(name, points, panel)
      values = panel[:mode] == :rate ? rate_values(points) : gauge_values(points)
      { name: name, values: values }
    end

    # Highest reading in each bucket. nil where nothing was recorded, so a gap
    # in recording draws as a gap rather than as a drop to zero.
    def gauge_values(points)
      buckets_values = Array.new(buckets.size)

      points.each do |_labels, value, at|
        index = bucket_index_for(at)
        next if index.nil?

        current = buckets_values[index]
        buckets_values[index] = current.nil? ? value : [ current, value ].max
      end

      carry_forward(buckets_values)
    end

    # A gauge holds its value until a later reading contradicts it: a bucket
    # with no sample means we did not look, not that the quantity vanished.
    # Drawing those as gaps rendered a constant 553k line as a dashed comb.
    #
    # Bounded, though, because one kind of gap is still real: past STALENESS
    # with no sample the recorder has stopped, and a line that keeps drawing its
    # last value there is a confident lie of exactly the kind this dashboard
    # exists to avoid. Same bound, for the same reason, that Prometheus uses.
    def carry_forward(values)
      limit = (STALENESS / bucket).ceil
      held = nil
      age = 0

      values.map do |value|
        if value.nil?
          age += 1
          (held if age <= limit)
        else
          held = value
          age = 0
          value
        end
      end
    end

    # How much the counter advanced within each bucket. A decrease means the
    # series restarted (a process restart resets an in-memory counter, and
    # PromQL treats it the same way), so it contributes its new value rather
    # than a negative.
    def rate_values(points)
      totals = Array.new(buckets.size, nil)
      previous = nil

      points.each do |_labels, value, at|
        index = bucket_index_for(at)
        if previous.nil?
          previous = value
          next
        end

        delta = value - previous
        delta = value if delta.negative?
        previous = value
        next if index.nil?

        totals[index] = (totals[index] || 0) + delta
      end

      # Zero, not nil, for buckets we observed: "nothing failed in this bucket"
      # is a real reading, unlike "we recorded nothing here".
      observed_range(points).each { |index| totals[index] ||= 0 }
      totals
    end

    def observed_range(points)
      indexes = points.filter_map { |_labels, _value, at| bucket_index_for(at) }
      return [] if indexes.empty?

      (indexes.min..indexes.max)
    end

    # Rate panels list every job class that ever failed, most of them static.
    # Keep the ones with movement in this window.
    def prune(series, panel)
      return series unless panel[:mode] == :rate

      moved = series.select { |entry| entry[:values].compact.any?(&:positive?) }
      return series.first(RATE_SERIES_LIMIT) if moved.empty?

      moved.sort_by { |entry| -entry[:values].compact.sum }.first(RATE_SERIES_LIMIT)
    end

    def label_of(labels, group_by)
      return "total" if group_by.blank?

      labels.to_h[group_by].presence || "unlabelled"
    end
  end
end
