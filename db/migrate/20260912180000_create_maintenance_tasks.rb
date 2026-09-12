class CreateMaintenanceTasks < ActiveRecord::Migration[8.1]
  class MigrationMaintenanceTask < ActiveRecord::Base
    self.table_name = "maintenance_tasks"
  end

  def up
    create_table :maintenance_tasks do |t|
      t.string :definition_key, null: false
      t.string :task_key, null: false
      t.string :state, null: false, default: "pending"
      t.string :recurrence, null: false
      t.string :category, null: false
      t.string :title, null: false
      t.string :summary, null: false
      t.string :trigger_kind, null: false
      t.string :trigger_key, null: false
      t.string :required_role, null: false, default: "admin"
      t.string :concurrency_key
      t.string :current_step_key
      t.string :current_step_title
      t.bigint :total_units, null: false, default: 0
      t.bigint :completed_units, null: false, default: 0
      t.bigint :failed_units, null: false, default: 0
      t.integer :batch_size, null: false, default: 250
      t.integer :max_parallelism, null: false, default: 1
      t.integer :eta_seconds
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :paused_at
      t.datetime :cancelled_at
      t.datetime :dismissed_at
      t.bigint :requested_by_user_id
      t.bigint :dismissed_by_user_id
      t.text :last_error
      t.json :checkpoint, null: false
      t.json :metadata, null: false
      t.timestamps

      t.index :definition_key
      t.index :state
      t.index [ :state, :updated_at ], name: "idx_maintenance_tasks_state_updated"
      t.index [ :trigger_kind, :trigger_key ], name: "idx_maintenance_tasks_trigger"
      t.index :task_key, unique: true
    end

    create_table :maintenance_task_events do |t|
      t.references :maintenance_task, null: false, foreign_key: false
      t.string :level, null: false, default: "info"
      t.string :step_key
      t.string :step_title
      t.text :message, null: false
      t.bigint :units_done
      t.bigint :units_total
      t.json :metadata, null: false
      t.timestamps

      t.index [ :maintenance_task_id, :created_at, :id ], name: "idx_maintenance_task_events_task_created"
    end

    MigrationMaintenanceTask.reset_column_information
    seed_agents_backfill_task_if_needed
  end

  def down
    drop_table :maintenance_task_events
    drop_table :maintenance_tasks
  end

  private

  def seed_agents_backfill_task_if_needed
    return unless table_exists?(:agents)
    return unless table_exists?(:runs)
    return unless table_exists?(:chat_sessions)
    return unless table_exists?(:spawned_processes)
    return unless column_exists?(:spawned_processes, :agent_id)
    return unless agents_backfill_needed?

    now = Time.current
    MigrationMaintenanceTask.find_or_create_by!(task_key: "migration:20260910170000:agents_backfill") do |task|
      task.definition_key = "agents_backfill"
      task.state = "pending"
      task.recurrence = "one_off"
      task.category = "backfill"
      task.title = "Backfill Agent records"
      task.summary = "Creates Agent records for historical Runs, Chats, Design Doc agent runs, and spawned processes."
      task.trigger_kind = "migration"
      task.trigger_key = "20260910170000"
      task.required_role = "admin"
      task.concurrency_key = "agents_backfill"
      task.batch_size = 250
      task.max_parallelism = 1
      task.checkpoint = {}
      task.metadata = { "seeded_by_migration" => "20260912180000" }
      task.created_at = now
      task.updated_at = now
    end
  end

  def agents_backfill_needed?
    return true if select_value(<<~SQL).to_i.positive?
      SELECT 1
      FROM runs
      LEFT JOIN agents ON agents.resumable_type = 'Run' AND agents.resumable_id = runs.id
      WHERE agents.id IS NULL
      LIMIT 1
    SQL

    return true if select_value(<<~SQL).to_i.positive?
      SELECT 1
      FROM chat_sessions
      LEFT JOIN agents ON agents.resumable_type = 'ChatSession' AND agents.resumable_id = chat_sessions.id
      WHERE agents.id IS NULL
      LIMIT 1
    SQL

    if table_exists?(:design_doc_agent_runs)
      return true if select_value(<<~SQL).to_i.positive?
        SELECT 1
        FROM design_doc_agent_runs
        LEFT JOIN agents ON agents.resumable_type = 'DesignDocs::DesignDocAgentRun' AND agents.resumable_id = design_doc_agent_runs.id
        WHERE agents.id IS NULL
        LIMIT 1
      SQL
    end

    select_value(<<~SQL).to_i.positive?
      SELECT 1
      FROM spawned_processes
      WHERE agent_id IS NULL AND (run_id IS NOT NULL OR chat_session_id IS NOT NULL)
      LIMIT 1
    SQL
  end
end
