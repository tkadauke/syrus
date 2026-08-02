class AddGithubAppInstallationSyncStatusToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :github_app_installation_sync_started_at, :datetime unless column_exists?(:app_settings, :github_app_installation_sync_started_at)
    add_column :app_settings, :github_app_installation_sync_succeeded_at, :datetime unless column_exists?(:app_settings, :github_app_installation_sync_succeeded_at)
    add_column :app_settings, :github_app_installation_sync_duration_ms, :integer unless column_exists?(:app_settings, :github_app_installation_sync_duration_ms)
    add_column :app_settings, :github_app_installation_sync_records_seen, :integer unless column_exists?(:app_settings, :github_app_installation_sync_records_seen)
    add_column :app_settings, :github_app_installation_sync_error_class, :string unless column_exists?(:app_settings, :github_app_installation_sync_error_class)
    add_column :app_settings, :github_app_installation_sync_error_message, :text unless column_exists?(:app_settings, :github_app_installation_sync_error_message)
  end
end
