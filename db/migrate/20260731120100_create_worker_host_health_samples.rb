class CreateWorkerHostHealthSamples < ActiveRecord::Migration[8.1]
  def change
    create_table :worker_host_health_samples do |t|
      t.string :hostname, null: false
      t.string :role, null: false
      t.string :version, null: false
      t.datetime :observed_at, null: false

      t.float :cpu_used_percent
      t.float :load_1m
      t.float :load_5m
      t.float :load_15m

      t.float :memory_used_percent
      t.bigint :memory_available_bytes
      t.bigint :memory_total_bytes

      t.float :data_root_used_percent
      t.bigint :data_root_available_bytes
      t.bigint :data_root_total_bytes

      t.float :cpu_pressure_some
      t.float :cpu_pressure_full
      t.float :io_pressure_some
      t.float :io_pressure_full

      t.json :raw_metrics, null: false

      t.timestamps
    end

    unless index_exists?(:worker_host_health_samples, [ :hostname, :role, :observed_at ], name: "idx_worker_host_health_samples_host_role_observed")
      add_index :worker_host_health_samples, [ :hostname, :role, :observed_at ], unique: true, name: "idx_worker_host_health_samples_host_role_observed"
    end
    add_index :worker_host_health_samples, :observed_at unless index_exists?(:worker_host_health_samples, :observed_at)
  end
end
