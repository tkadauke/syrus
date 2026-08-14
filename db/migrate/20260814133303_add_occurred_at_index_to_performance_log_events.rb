class AddOccurredAtIndexToPerformanceLogEvents < ActiveRecord::Migration[8.1]
  def change
    unless index_exists?(:performance_log_events, :occurred_at, name: "idx_perf_events_occurred_at")
      add_index :performance_log_events, :occurred_at, name: "idx_perf_events_occurred_at"
    end
  end
end
