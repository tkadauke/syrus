# Cumulative totals for counters declared `cluster: true`, summed across every
# process (web, and each forked Solid Queue worker) -- see
# Metrics::ClusterCounters. One row per counter and label set; processes add
# their deltas with an atomic `value = value + delta` upsert.
class CreateMetricCounterTotals < ActiveRecord::Migration[8.1]
  def up
    create_table :metric_counter_totals, if_not_exists: true do |t|
      t.string :name, limit: 191, null: false
      # SHA-256 of the canonical label set: a fixed-length unique key, where
      # the labels themselves could exceed an index's length limit.
      t.string :labels_digest, limit: 64, null: false
      # No default: MySQL 8 refuses one on JSON columns.
      t.json :labels
      t.decimal :value, precision: 30, scale: 6, null: false, default: 0
      t.timestamps
    end
    unless index_exists?(:metric_counter_totals, [ :name, :labels_digest ])
      add_index :metric_counter_totals, [ :name, :labels_digest ], unique: true
    end
  end

  def down
    drop_table :metric_counter_totals, if_exists: true
  end
end
