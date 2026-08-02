class AddGithubAppInstallationSyncStatusToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :github_app_installation_sync_started_at, :datetime
    add_column :app_settings, :github_app_installation_sync_succeeded_at, :datetime
    add_column :app_settings, :github_app_installation_sync_duration_ms, :integer
    add_column :app_settings, :github_app_installation_sync_records_seen, :integer
    add_column :app_settings, :github_app_installation_sync_error_class, :string
    add_column :app_settings, :github_app_installation_sync_error_message, :text
  end
end
