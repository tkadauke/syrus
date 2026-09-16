# One recorded value of one metric series at one minute.
#
# Named with the plugin's prefix on purpose: Syrus::PluginPurge finds a plugin's
# tables by that prefix, so this is what makes the plugin genuinely uninstallable
# rather than merely disableable.
module MetricsDashboard
  class Sample < ApplicationRecord
    self.table_name = "metrics_dashboard_samples"

    include HasConfigurableRetention

    configurable_retention setting_key: :metrics_dashboard_sample_retention_days, unit: :days

    validates :metric, :recorded_at, presence: true
    validates :value, presence: true
    # Not `presence`: "" is the correct series key for a metric with no labels,
    # and presence rejects an empty string. The column is NOT NULL, which is the
    # constraint that actually matters. (The recorder writes through upsert_all,
    # which skips validations, so this only ever bit direct creates -- which is
    # exactly the kind of gap that stays hidden until something else uses the
    # model.)
    validates :series_key, exclusion: { in: [ nil ] }

    scope :since, ->(time) { where(recorded_at: time..) }
    scope :for_metric, ->(metric) { where(metric: metric) }
    scope :prunable, -> {
      cutoff = retention_cutoff
      cutoff ? where(recorded_at: ...cutoff) : none
    }

    # MySQL 8 rejects defaults on JSON columns, so the default is seeded here
    # rather than in the schema (see CLAUDE.md).
    after_initialize { self.labels ||= {} if has_attribute?(:labels) }

    # A stable identity for "the same series" across samples. Sorted so that two
    # renderings of the same label set never produce two series.
    def self.series_key_for(labels)
      return "" if labels.blank?

      labels.sort.map { |key, value| "#{key}=#{value}" }.join(",")
    end
  end
end
