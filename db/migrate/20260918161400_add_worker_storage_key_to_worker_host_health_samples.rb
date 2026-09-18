class AddWorkerStorageKeyToWorkerHostHealthSamples < ActiveRecord::Migration[8.1]
  def change
    add_column :worker_host_health_samples, :worker_storage_key, :string
    add_index :worker_host_health_samples, [ :worker_storage_key, :role, :observed_at ],
              name: "idx_worker_health_storage_role_observed"
  end
end
