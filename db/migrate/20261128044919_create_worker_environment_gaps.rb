class CreateWorkerEnvironmentGaps < ActiveRecord::Migration[8.1]
  def up
    create_table :worker_environment_gaps, if_not_exists: true do |t|
      t.string :hostname, null: false
      t.string :worker_storage_key
      t.integer :repository_id
      t.string :missing_kind, null: false
      t.string :missing_name
      t.integer :run_id
      t.json :evidence
      t.datetime :detected_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :cleared_at
      t.timestamps
    end

    add_index :worker_environment_gaps, [ :hostname, :cleared_at ], name: "idx_worker_environment_gaps_host_active" unless index_exists?(:worker_environment_gaps, [ :hostname, :cleared_at ], name: "idx_worker_environment_gaps_host_active")
    add_index :worker_environment_gaps, [ :repository_id, :cleared_at ], name: "idx_worker_environment_gaps_repo_active" unless index_exists?(:worker_environment_gaps, [ :repository_id, :cleared_at ], name: "idx_worker_environment_gaps_repo_active")
  end

  def down
    drop_table :worker_environment_gaps, if_exists: true
  end
end
