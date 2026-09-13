class CreateMetricsDashboardSamples < ActiveRecord::Migration[8.1]
  # One row per metric series per minute. Deliberately not a time-series
  # database: fixed resolution, fixed retention, and no ambition beyond the
  # fixed panels this plugin draws. An install that needs arbitrary queries
  # needs Prometheus, and /metrics is already there for it.
  #
  # Guarded throughout: a production migration that dies partway through (OOM,
  # eviction, lock contention) does not record its version, and the retry then
  # crashes on the already-created table.
  def up
    unless table_exists?(:metrics_dashboard_samples)
      create_table :metrics_dashboard_samples, if_not_exists: true do |t|
        t.string :metric, null: false, limit: 190
        # The label set, as rendered. MySQL 8 rejects defaults on JSON columns,
        # so this is nullable and the model seeds {} -- see CLAUDE.md.
        t.json :labels
        # Identifies the series within a metric without re-serialising the
        # label hash on every read, and keeps the uniqueness index short enough
        # for MySQL's key length limit.
        t.string :series_key, null: false, limit: 190
        t.float :value, null: false
        t.datetime :recorded_at, null: false
      end
    end

    unless index_exists?(:metrics_dashboard_samples, %i[metric series_key recorded_at])
      add_index :metrics_dashboard_samples, %i[metric series_key recorded_at],
                unique: true, name: "idx_metrics_dashboard_series_minute"
    end
    unless index_exists?(:metrics_dashboard_samples, :recorded_at)
      add_index :metrics_dashboard_samples, :recorded_at
    end
  end

  def down
    drop_table :metrics_dashboard_samples, if_exists: true
  end
end
