class AddAttributionFamiliesToResourceProfiles < ActiveRecord::Migration[8.1]
  def change
    change_table :run_resource_summaries, bulk: true do |t|
      t.integer :process_attributed_sample_count, null: false, default: 0
      t.float :process_attributed_duration_seconds
      t.float :process_attributed_cpu_seconds
      t.float :process_attributed_cpu_percent
      t.bigint :process_attributed_memory_bytes
      t.bigint :process_attributed_io_bytes
    end

    change_table :workflow_step_resource_profiles, bulk: true do |t|
      t.integer :process_attributed_sample_count, null: false, default: 0
      t.integer :host_pressure_sample_count, null: false, default: 0
      t.string :attribution_quality, limit: 32, null: false, default: "host_correlated"

      t.float :p50_process_attributed_duration_seconds
      t.float :p90_process_attributed_duration_seconds
      t.float :p99_process_attributed_duration_seconds
      t.float :p50_process_attributed_cpu_seconds
      t.float :p90_process_attributed_cpu_seconds
      t.float :p99_process_attributed_cpu_seconds
      t.float :p50_process_attributed_cpu_percent
      t.float :p90_process_attributed_cpu_percent
      t.float :p99_process_attributed_cpu_percent
      t.bigint :p50_process_attributed_memory_bytes
      t.bigint :p90_process_attributed_memory_bytes
      t.bigint :p99_process_attributed_memory_bytes
      t.bigint :p50_process_attributed_io_bytes
      t.bigint :p90_process_attributed_io_bytes
      t.bigint :p99_process_attributed_io_bytes

      t.float :p50_host_pressure_cpu
      t.float :p90_host_pressure_cpu
      t.float :p99_host_pressure_cpu
      t.float :p50_host_pressure_io
      t.float :p90_host_pressure_io
      t.float :p99_host_pressure_io
      t.float :p50_host_pressure_memory_used_percent
      t.float :p90_host_pressure_memory_used_percent
      t.float :p99_host_pressure_memory_used_percent
    end
  end
end
