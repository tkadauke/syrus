class AddRevisionOccurredIdIndexToPerformanceLogEvents < ActiveRecord::Migration[8.1]
  def up
    add_index :performance_log_events,
              [ :app_revision, :occurred_at, :id ],
              name: "idx_perf_events_revision_occurred_id",
              if_not_exists: true

    remove_index :performance_log_events,
                 name: "idx_perf_events_revision_occurred",
                 if_exists: true
  end

  def down
    add_index :performance_log_events,
              [ :app_revision, :occurred_at ],
              name: "idx_perf_events_revision_occurred",
              if_not_exists: true

    remove_index :performance_log_events,
                 name: "idx_perf_events_revision_occurred_id",
                 if_exists: true
  end
end
