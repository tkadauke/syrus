class ReducePerformanceLogWriteIndexes < ActiveRecord::Migration[8.1]
  def change
    remove_index :performance_log_events, name: "idx_perf_events_path_occurred", if_exists: true
    remove_index :performance_log_events, name: "idx_perf_events_phase_occurred", if_exists: true
    remove_index :performance_log_events, name: "idx_perf_events_sql_fingerprint_occurred", if_exists: true
  end
end
