class CreateCommandSpans < ActiveRecord::Migration[8.1]
  def up
    create_table :command_spans, if_not_exists: true do |t|
      t.bigint :job_id, null: false
      t.bigint :workflow_id, null: false
      t.bigint :step_id, null: false
      t.bigint :run_id, null: false
      t.bigint :spawned_process_id
      t.integer :sequence, null: false
      t.string :name, null: false, limit: 128
      t.string :command_excerpt, null: false, limit: 1024
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer :duration_ms
      t.integer :exit_status
      t.string :outcome, limit: 32
      t.string :hostname, limit: 255
      t.json :metadata, null: false

      t.timestamps
    end

    unless index_exists?(:command_spans, [ :run_id, :sequence ], name: "index_command_spans_on_run_id_and_sequence")
      add_index :command_spans, [ :run_id, :sequence ], unique: true
    end
    unless index_exists?(:command_spans, [ :workflow_id, :step_id ], name: "index_command_spans_on_workflow_id_and_step_id")
      add_index :command_spans, [ :workflow_id, :step_id ]
    end
    add_index :command_spans, :spawned_process_id unless index_exists?(:command_spans, :spawned_process_id)
    unless index_exists?(:command_spans, [ :hostname, :started_at ], name: "index_command_spans_on_hostname_and_started_at")
      add_index :command_spans, [ :hostname, :started_at ]
    end

    add_foreign_key :command_spans, :jobs unless foreign_key_exists?(:command_spans, :jobs)
    add_foreign_key :command_spans, :workflows unless foreign_key_exists?(:command_spans, :workflows)
    add_foreign_key :command_spans, :steps unless foreign_key_exists?(:command_spans, :steps)
    add_foreign_key :command_spans, :runs unless foreign_key_exists?(:command_spans, :runs)
    add_foreign_key :command_spans, :spawned_processes unless foreign_key_exists?(:command_spans, :spawned_processes)
  end

  def down
    drop_table :command_spans, if_exists: true
  end
end
