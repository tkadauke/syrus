class AddFailedHostContextToAutoRetryAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :auto_retry_attempts, :failed_worker_hostname, :string unless column_exists?(:auto_retry_attempts, :failed_worker_hostname)
    add_column :auto_retry_attempts, :failed_worker_health_level, :string unless column_exists?(:auto_retry_attempts, :failed_worker_health_level)
    add_column :auto_retry_attempts, :failed_worker_health_reasons, :json unless column_exists?(:auto_retry_attempts, :failed_worker_health_reasons)
    add_column :auto_retry_attempts, :failed_worker_sample_observed_at, :datetime unless column_exists?(:auto_retry_attempts, :failed_worker_sample_observed_at)
    add_column :auto_retry_attempts, :failed_worker_retry_deferred_until, :datetime unless column_exists?(:auto_retry_attempts, :failed_worker_retry_deferred_until)
    add_column :auto_retry_attempts, :failed_worker_retry_context, :json unless column_exists?(:auto_retry_attempts, :failed_worker_retry_context)

    unless index_exists?(:auto_retry_attempts, [ :failed_worker_hostname, :failed_worker_retry_deferred_until ], name: "idx_auto_retry_attempts_failed_worker_retry")
      add_index :auto_retry_attempts,
                [ :failed_worker_hostname, :failed_worker_retry_deferred_until ],
                name: "idx_auto_retry_attempts_failed_worker_retry"
    end
  end
end
