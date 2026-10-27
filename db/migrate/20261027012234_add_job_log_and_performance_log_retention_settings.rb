class AddJobLogAndPerformanceLogRetentionSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :job_log_retention_days, :integer, default: 30, null: false unless column_exists?(:app_settings, :job_log_retention_days)
    add_column :app_settings, :job_log_archive_before_delete, :boolean, default: false, null: false unless column_exists?(:app_settings, :job_log_archive_before_delete)
    add_column :app_settings, :performance_log_event_retention_hours, :integer, default: 24, null: false unless column_exists?(:app_settings, :performance_log_event_retention_hours)
    add_index :job_logs, :created_at unless index_exists?(:job_logs, :created_at)
  end

  def down
    remove_index :job_logs, :created_at if index_exists?(:job_logs, :created_at)
    remove_column :app_settings, :performance_log_event_retention_hours if column_exists?(:app_settings, :performance_log_event_retention_hours)
    remove_column :app_settings, :job_log_archive_before_delete if column_exists?(:app_settings, :job_log_archive_before_delete)
    remove_column :app_settings, :job_log_retention_days if column_exists?(:app_settings, :job_log_retention_days)
  end
end
