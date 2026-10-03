class AddMacosUpdaterStatusToWorkerHealth < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :macos_worker_desired_release, :json unless column_exists?(:app_settings, :macos_worker_desired_release)
    add_column :instance_versions, :desired_version, :json unless column_exists?(:instance_versions, :desired_version)
    add_column :instance_versions, :macos_updater_status, :json unless column_exists?(:instance_versions, :macos_updater_status)
    add_column :worker_host_health_samples, :desired_version, :json unless column_exists?(:worker_host_health_samples, :desired_version)
    add_column :worker_host_health_samples, :macos_updater_status, :json unless column_exists?(:worker_host_health_samples, :macos_updater_status)
  end
end
