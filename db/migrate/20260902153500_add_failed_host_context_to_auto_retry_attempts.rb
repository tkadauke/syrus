class AddFailedHostContextToAutoRetryAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :auto_retry_attempts, :failed_hostname, :string, limit: 255
    add_column :auto_retry_attempts, :failed_host_pressure_level, :string, limit: 32
    add_column :auto_retry_attempts, :failed_host_pressure_started_at, :datetime
    add_column :auto_retry_attempts, :failed_host_pressure_finished_at, :datetime
    add_column :auto_retry_attempts, :failed_host_pressure_sample_count, :integer
    add_column :auto_retry_attempts, :failed_host_pressure_reasons, :json

    add_index :auto_retry_attempts,
              [ :workflow_id, :failed_hostname, :failure_classification, :scheduled_at ],
              name: "idx_auto_retry_attempts_failed_host_context"
  end
end
