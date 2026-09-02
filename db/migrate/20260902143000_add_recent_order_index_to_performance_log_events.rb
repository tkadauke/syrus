class AddRecentOrderIndexToPerformanceLogEvents < ActiveRecord::Migration[8.1]
  def up
    add_index :performance_log_events,
      [ :occurred_at, :id ],
      name: "idx_perf_events_occurred_at_id",
      if_not_exists: true

    remove_index :performance_log_events,
      name: "idx_perf_events_occurred_at",
      if_exists: true
  end

  def down
    add_index :performance_log_events,
      :occurred_at,
      name: "idx_perf_events_occurred_at",
      if_not_exists: true

    remove_index :performance_log_events,
      name: "idx_perf_events_occurred_at_id",
      if_exists: true
  end
end
