module Coworkers
  class MetricsDashboardSummary
    COLUMNS = %w[coworker journaling_state journaling_age unsaved_age spend].freeze

    def self.build = new.build

    def build
      snapshot = Rails.cache.read(MetricsSampler::CACHE_KEY) || {}
      {
        title: t("title"),
        columns: COLUMNS.map { |key| { key:, label: t("columns.#{key}") } },
        rows: Hash(snapshot["coworkers"]).sort.map { |handle, values| row(handle, values) }
      }
    end

    private

    def row(handle, values)
      state = values["journaling_state"]
      journaling_age = values["journaling_age"]
      unsaved_age = values["unsaved_age"].to_f
      {
        key: handle,
        stale: (state != "paused" && journaling_age.to_f > 36.hours) || unsaved_age > 1.hour,
        values: {
          coworker: handle,
          journaling_state: state ? t("states.#{state}") : t("no_schedule"),
          journaling_age: age(journaling_age, empty: "never"),
          unsaved_age: age(unsaved_age, empty: "none"),
          spend: ActionController::Base.helpers.number_to_currency(
            values["weekly_spend"].to_f,
            unit: t("currency.unit"),
            format: t("currency.format"),
            separator: t("currency.separator"),
            delimiter: t("currency.delimiter")
          )
        }
      }
    end

    def age(value, empty:)
      return t(empty) unless value.to_f.positive?

      t("age_hours", count: (value.to_f / 1.hour).round(1))
    end

    def t(key, **) = I18n.t("api.coworkers.metrics_dashboard.#{key}", **)
  end
end
