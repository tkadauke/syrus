class AddMacosUpdaterStatusToWorkerHealth < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :macos_worker_desired_release, :json
    add_column :instance_versions, :desired_version, :json
    add_column :instance_versions, :macos_updater_status, :json
    add_column :worker_host_health_samples, :desired_version, :json
    add_column :worker_host_health_samples, :macos_updater_status, :json
  end
end
