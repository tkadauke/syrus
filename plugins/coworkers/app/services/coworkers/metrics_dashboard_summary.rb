module Coworkers
  class MetricsDashboardSummary
    WINDOW = 7.days
    CURRENT_WITHIN = 5.minutes
    STALE_WARNING = 36.hours
    STALE_CRITICAL = 72.hours
    UNSAVED_WARNING = 1.hour
    UNSAVED_CRITICAL = 6.hours
    METRICS = %w[
      syrus_coworkers_journaling_state
      syrus_coworkers_journaling_last_result_age_seconds
      syrus_coworkers_unsaved_workspace_age_seconds
      syrus_coworkers_spend_usd_total
    ].freeze

    def self.build = new.build

    def build
      @window_start = WINDOW.ago
      samples = MetricsDashboard::Sample.where(metric: METRICS, recorded_at: (@window_start - CURRENT_WITHIN)..)
        .order(:recorded_at).pluck(:metric, :labels, :value, :recorded_at)
      by_metric = samples.group_by(&:first)
      handles = samples.filter_map do |metric, labels, _value, at|
        labels["coworker"] if metric == "syrus_coworkers_journaling_state" && at >= CURRENT_WITHIN.ago
      end.uniq.sort

      { key: "coworkers_health", label: translate(:title), columns:, rows: handles.map { |handle| row(handle, by_metric) } }
    end

    private

    def columns
      [
        { key: "coworker", label: translate("columns.coworker") },
        { key: "journaling_state", label: translate("columns.journaling_state") },
        { key: "journaling_age", label: translate("columns.journaling_age") },
        { key: "unsaved_age", label: translate("columns.unsaved_age") },
        { key: "spend_7d", label: translate("columns.spend_7d") }
      ]
    end

    def row(handle, samples)
      state = current_state(samples["syrus_coworkers_journaling_state"], handle)
      journaling_age = latest_value(samples["syrus_coworkers_journaling_last_result_age_seconds"], handle)
      unsaved_age = latest_value(samples["syrus_coworkers_unsaved_workspace_age_seconds"], handle)
      spend = counter_increase(samples["syrus_coworkers_spend_usd_total"], handle)

      {
        key: handle,
        tone: tone(state:, journaling_age:, unsaved_age:),
        cells: {
          coworker: handle,
          journaling_state: state ? translate("states.#{state}") : translate(:no_schedule),
          journaling_age: duration(journaling_age),
          unsaved_age: unsaved_age.to_f.positive? ? duration(unsaved_age) : translate(:none),
          spend_7d: spend_value(spend)
        }
      }.compact
    end

    def matching(rows, handle)
      Array(rows).select { |_metric, labels, _value, _at| labels["coworker"] == handle }
    end

    def current_state(rows, handle)
      current = matching(rows, handle)
      latest_at = current.map(&:last).max
      return if latest_at.nil?

      current.find { |_metric, _labels, value, at| at == latest_at && value.to_f == 1.0 }&.dig(1, "state")
    end

    def latest_value(rows, handle) = matching(rows, handle).max_by(&:last)&.third

    def counter_increase(rows, handle)
      matching(rows, handle).group_by { |_metric, labels, _value, _at| labels["source"] }.sum do |_source, points|
        points.each_cons(2).sum do |before, after|
          next 0 if after.last < @window_start

          delta = after.third.to_f - before.third.to_f
          delta.negative? ? after.third.to_f : delta
        end
      end
    end

    def tone(state:, journaling_age:, unsaved_age:)
      return "critical" if state == "auto_paused" || (state != "paused" && journaling_age.to_f > STALE_CRITICAL) || unsaved_age.to_f > UNSAVED_CRITICAL
      return "warning" if (state != "paused" && journaling_age.to_f > STALE_WARNING) || unsaved_age.to_f > UNSAVED_WARNING
    end

    def duration(seconds)
      return translate(:never) if seconds.nil?

      value = seconds.to_f
      return translate(:days, count: (value / 1.day).floor) if value >= 1.day
      return translate(:hours, count: (value / 1.hour).floor) if value >= 1.hour

      translate(:minutes, count: (value / 1.minute).floor)
    end

    def spend_value(spend)
      amount = format("%.2f", spend).tr(".", translate(:decimal_separator))
      translate(:spend, amount:)
    end

    def translate(key, **) = I18n.t("api.coworkers.metrics_dashboard.#{key}", **)
  end
end
