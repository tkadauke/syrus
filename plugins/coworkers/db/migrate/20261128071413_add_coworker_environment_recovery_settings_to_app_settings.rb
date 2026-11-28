class AddCoworkerEnvironmentRecoverySettingsToAppSettings < ActiveRecord::Migration[8.1]
  def up
    add_column :app_settings, :coworker_environment_rollback_retention_count, :integer, default: 2, null: false unless column_exists?(:app_settings, :coworker_environment_rollback_retention_count)
    add_column :app_settings, :coworker_environment_launch_failure_threshold, :integer, default: 3, null: false unless column_exists?(:app_settings, :coworker_environment_launch_failure_threshold)
  end

  def down
    remove_column :app_settings, :coworker_environment_launch_failure_threshold if column_exists?(:app_settings, :coworker_environment_launch_failure_threshold)
    remove_column :app_settings, :coworker_environment_rollback_retention_count if column_exists?(:app_settings, :coworker_environment_rollback_retention_count)
  end
end
