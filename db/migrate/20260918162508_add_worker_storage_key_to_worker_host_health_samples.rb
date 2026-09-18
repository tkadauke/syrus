class AddWorkerStorageKeyToWorkerHostHealthSamples < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:worker_host_health_samples, :worker_storage_key)
      add_column :worker_host_health_samples, :worker_storage_key, :string
    end

    unless index_exists?(:worker_host_health_samples, [ :worker_storage_key, :role, :observed_at ],
                         name: "idx_worker_health_storage_role_observed")
      add_index :worker_host_health_samples, [ :worker_storage_key, :role, :observed_at ],
                name: "idx_worker_health_storage_role_observed"
    end
  end
end
