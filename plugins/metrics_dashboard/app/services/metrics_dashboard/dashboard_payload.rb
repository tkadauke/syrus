module MetricsDashboard
  # The fixed set of panels this plugin draws.
  #
  # Deliberately not a query builder. It answers the questions the dashboard
  # plan opened with -- is the queue keeping up, what is red, which features are
  # used -- and nothing else. An install that needs arbitrary queries needs
  # Prometheus, and /metrics is already there for it; growing a query language
  # here would be reimplementing a time-series database in Rails.
  class DashboardPayload
    WINDOWS = { "1h" => 1.hour, "6h" => 6.hours, "24h" => 24.hours, "7d" => 7.days }.freeze
    DEFAULT_WINDOW = "6h".freeze

    # Each panel names one metric and how to read it. `aggregate` is the honest
    # part: syrus_global_* series are one cluster-wide fact rendered identically
    # by every pod, so summing them multiplies by the number of recorders. Max is
    # the only correct reduction, and encoding it here means no one has to
    # remember the rule.
    PANELS = [
      { key: "queue_oldest_age", metric: "syrus_global_queue_oldest_age_seconds",
        group_by: "queue", aggregate: :max, unit: "seconds" },
      { key: "queue_ready", metric: "syrus_global_queue_ready_count",
        group_by: "queue", aggregate: :max, unit: "jobs" },
      { key: "queue_failed", metric: "syrus_global_queue_failed_count",
        group_by: "job_class", aggregate: :max, unit: "executions" },
      { key: "queue_orphaned", metric: "syrus_global_queue_orphaned_rows",
        group_by: nil, aggregate: :max, unit: "rows" },
      { key: "feature_usage", metric: "syrus_feature_used_total",
        group_by: "feature", aggregate: :sum, unit: "uses" }
    ].freeze

    def self.build(window: DEFAULT_WINDOW) = new(window: window).build

    def initialize(window: DEFAULT_WINDOW)
      @window = WINDOWS.key?(window) ? window : DEFAULT_WINDOW
    end

    def build
      {
        window: @window,
        windows: WINDOWS.keys,
        recording: recording?,
        last_recorded_at: last_recorded_at&.iso8601,
        panels: PANELS.map { |panel| series_for(panel) }
      }
    end

    private

    def since = WINDOWS.fetch(@window).ago

    # Absent rather than zero when nothing has been recorded: a chart of zeroes
    # would claim the queue is empty when the truth is that nobody looked.
    def recording? = last_recorded_at.present? && last_recorded_at > 5.minutes.ago

    def last_recorded_at
      return @last_recorded_at if defined?(@last_recorded_at)

      @last_recorded_at = MetricsDashboardSample.maximum(:recorded_at)
    end

    def series_for(panel)
      rows = MetricsDashboardSample
        .for_metric(panel[:metric])
        .since(since)
        .order(:recorded_at)
        .pluck(:labels, :value, :recorded_at)

      {
        key: panel[:key],
        metric: panel[:metric],
        unit: panel[:unit],
        aggregate: panel[:aggregate].to_s,
        series: group_series(rows, panel)
      }
    end

    # One line per label value, each a list of [timestamp, value] points.
    def group_series(rows, panel)
      grouped = rows.group_by { |labels, _value, _at| label_of(labels, panel[:group_by]) }

      grouped.map do |name, points|
        {
          name: name,
          points: points.map { |_labels, value, at| [ at.iso8601, value ] }
        }
      end.sort_by { |series| series[:name].to_s }
    end

    def label_of(labels, group_by)
      return "total" if group_by.blank?

      labels.to_h[group_by].presence || "unlabelled"
    end
  end
end
