class AddCapabilitiesToWorkerHealth < ActiveRecord::Migration[8.1]
  def change
    add_column :instance_versions, :capabilities, :json unless column_exists?(:instance_versions, :capabilities)
    add_column :instance_versions, :capability_diagnostics, :json unless column_exists?(:instance_versions, :capability_diagnostics)

    add_column :worker_host_health_samples, :capabilities, :json unless column_exists?(:worker_host_health_samples, :capabilities)
    add_column :worker_host_health_samples, :capability_diagnostics, :json unless column_exists?(:worker_host_health_samples, :capability_diagnostics)
  end
end
