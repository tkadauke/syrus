class CreateSpawnedProcesses < ActiveRecord::Migration[8.1]
  # Every subprocess Syrus spawns (agent CLI, grader command, git
  # operation, prepare command) gets a row in this table at spawn
  # time, heartbeats while running, and finalizes on exit. Powers
  # the admin /processes page + API and the cross-pod kill switch.
  # Guarded so partial deploys don't crash retries (docs/agent-guide/conventions.md).
  def up
    return if table_exists?(:spawned_processes)

    create_table :spawned_processes do |t|
      t.string :kind, null: false, limit: 32
      t.string :command, null: false, limit: 4096
      t.string :workdir, limit: 4096
      t.string :hostname, null: false, limit: 255
      t.integer :pid
      t.integer :pgid
      t.datetime :started_at, null: false
      t.datetime :last_chunk_at
      t.datetime :finished_at
      t.integer :exit_status
      t.string :outcome, limit: 32
      t.integer :wall_timeout_s
      t.integer :silent_timeout_s
      t.references :run, foreign_key: { to_table: :runs }, null: true
      t.references :workflow, foreign_key: { to_table: :workflows }, null: true
      t.datetime :kill_requested_at
      t.references :kill_requested_by_user, foreign_key: { to_table: :users }, null: true
      t.timestamps

      t.index :kind
      t.index :hostname
      t.index :finished_at
      t.index [ :finished_at, :last_chunk_at ], name: "idx_spawned_processes_active"
    end
  end

  def down
    drop_table :spawned_processes if table_exists?(:spawned_processes)
  end
end
