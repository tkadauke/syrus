# The dashboard history query filters on `metric` and a `recorded_at` range and
# orders by `recorded_at`. The unique series index is (metric, series_key,
# recorded_at); `series_key` sits between the two, so it cannot serve the range
# scan or the ordering and MySQL ends up scanning and filesorting a whole
# metric. (metric, recorded_at) serves both directly.
#
# The unique series index stays (it is the upsert conflict target), and so does
# the standalone recorded_at index (retention pruning filters on time alone).
class AddMetricRecordedAtIndexToMetricsDashboardSamples < ActiveRecord::Migration[8.1]
  INDEX = "idx_metrics_dashboard_metric_recorded_at".freeze

  def up
    return unless table_exists?(:metrics_dashboard_samples)

    unless index_exists?(:metrics_dashboard_samples, %i[metric recorded_at], name: INDEX)
      # Online on MySQL: in-place build without blocking writes.
      if connection.adapter_name =~ /mysql|trilogy/i
        add_index :metrics_dashboard_samples, %i[metric recorded_at], name: INDEX,
                  algorithm: :inplace, lock: :none
      else
        add_index :metrics_dashboard_samples, %i[metric recorded_at], name: INDEX
      end
    end
  end

  def down
    return unless table_exists?(:metrics_dashboard_samples)

    remove_index :metrics_dashboard_samples, name: INDEX if index_exists?(:metrics_dashboard_samples, nil, name: INDEX)
  end
end
