class CreateRunResourceSummaries < ActiveRecord::Migration[8.1]
  def up
    create_table :run_resource_summaries, if_not_exists: true do |t|
      t.bigint :run_id, null: false
      t.bigint :job_id, null: false
      t.bigint :workflow_id
      t.bigint :step_id
      t.bigint :repository_id
      t.bigint :user_id, null: false

      t.string :agent_provider, null: false, limit: 64
      t.string :trigger_kind, null: false, limit: 64
      t.string :step_kind, limit: 64
      t.string :grader_name, limit: 128
      t.string :hostname, limit: 255

      t.datetime :started_at
      t.datetime :finished_at
      t.float :duration_seconds

      t.integer :host_sample_count, null: false, default: 0
      t.string :sample_confidence, null: false, limit: 32
      t.float :avg_cpu_used_percent
      t.float :max_cpu_used_percent
      t.float :avg_cpu_pressure
      t.float :max_cpu_pressure
      t.float :avg_memory_used_percent
      t.float :max_memory_used_percent
      t.float :avg_io_pressure
      t.float :max_io_pressure
      t.float :max_data_root_used_percent

      t.integer :spawned_process_count, null: false, default: 0
      t.integer :command_span_count, null: false, default: 0
      t.string :resource_pressure_level, null: false, limit: 32
      t.json :resource_pressure_reasons, null: false
      t.boolean :retention_limited, null: false, default: false
      t.integer :summary_version, null: false

      t.timestamps
    end

    unless index_exists?(:run_resource_summaries, :run_id)
      add_index :run_resource_summaries, :run_id, unique: true
    end

    unless index_exists?(:run_resource_summaries, :job_id)
      add_index :run_resource_summaries, :job_id
    end

    unless index_exists?(:run_resource_summaries, :workflow_id)
      add_index :run_resource_summaries, :workflow_id
    end

    add_index :run_resource_summaries, [ :repository_id, :step_kind, :created_at ], name: "idx_run_resource_summaries_repo_step_created" unless index_exists?(:run_resource_summaries, [ :repository_id, :step_kind, :created_at ], name: "idx_run_resource_summaries_repo_step_created")
    add_index :run_resource_summaries, [ :hostname, :started_at ], name: "idx_run_resource_summaries_host_started" unless index_exists?(:run_resource_summaries, [ :hostname, :started_at ], name: "idx_run_resource_summaries_host_started")

    add_foreign_key :run_resource_summaries, :runs unless foreign_key_exists?(:run_resource_summaries, :runs)
    add_foreign_key :run_resource_summaries, :jobs unless foreign_key_exists?(:run_resource_summaries, :jobs)
    add_foreign_key :run_resource_summaries, :workflows unless foreign_key_exists?(:run_resource_summaries, :workflows)
    add_foreign_key :run_resource_summaries, :steps unless foreign_key_exists?(:run_resource_summaries, :steps)
    add_foreign_key :run_resource_summaries, :repositories unless foreign_key_exists?(:run_resource_summaries, :repositories)
    add_foreign_key :run_resource_summaries, :users unless foreign_key_exists?(:run_resource_summaries, :users)
  end

  def down
    drop_table :run_resource_summaries, if_exists: true
  end
end
