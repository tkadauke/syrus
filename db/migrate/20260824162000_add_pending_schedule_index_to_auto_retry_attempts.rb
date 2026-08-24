class AddPendingScheduleIndexToAutoRetryAttempts < ActiveRecord::Migration[8.1]
  def up
    unless index_exists?(:auto_retry_attempts, [ :performed_at, :skipped_reason, :scheduled_at, :id ], name: "idx_auto_retry_attempts_pending_schedule")
      add_index :auto_retry_attempts,
                [ :performed_at, :skipped_reason, :scheduled_at, :id ],
                name: "idx_auto_retry_attempts_pending_schedule"
    end
  end

  def down
    remove_index :auto_retry_attempts,
                 name: "idx_auto_retry_attempts_pending_schedule",
                 if_exists: true
  end
end
