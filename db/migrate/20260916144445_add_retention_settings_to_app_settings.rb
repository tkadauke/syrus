class AddRetentionSettingsToAppSettings < ActiveRecord::Migration[8.1]
  # Defaults match the RETAIN_AFTER/RETENTION constants they replace exactly,
  # so behavior doesn't change until an operator edits a setting. See
  # RetentionPolicyRegistry for the declarative source of truth.
  COLUMNS = {
    run_diagnostic_retention_days: 30,
    run_resource_summary_retention_days: 30,
    worker_host_health_sample_retention_days: 7,
    work_engine_reconciler_activity_retention_days: 7,
    provider_session_retention_days: 14,
    spawned_process_retention_days: 7,
    notification_retention_days: 30,
    operational_log_event_retention_hours: 6,
    metrics_dashboard_sample_retention_days: 30,
    run_health_snapshot_retention_days: 7,
    main_branch_health_check_retention_days: 7,
    workflow_step_resource_profile_retention_days: 180,
    workflow_step_resource_profile_input_retention_days: 180
  }.freeze

  def up
    COLUMNS.each do |column, default|
      next if column_exists?(:app_settings, column)

      add_column :app_settings, column, :integer, default: default, null: false
    end
  end

  def down
    COLUMNS.each_key do |column|
      remove_column :app_settings, column if column_exists?(:app_settings, column)
    end
  end
end
