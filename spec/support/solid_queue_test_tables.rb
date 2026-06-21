module SolidQueueTestTables
  def ensure_solid_queue_test_tables!
    connection = ActiveRecord::Base.connection

    unless connection.table_exists?(:solid_queue_jobs)
      connection.create_table :solid_queue_jobs do |t|
      t.string :active_job_id
      t.text :arguments
      t.string :class_name, null: false
      t.string :concurrency_key
      t.datetime :created_at, null: false
      t.datetime :finished_at
      t.integer :priority, default: 0, null: false
      t.string :queue_name, null: false
      t.datetime :scheduled_at
      t.datetime :updated_at, null: false
      end
    end

    unless connection.table_exists?(:solid_queue_claimed_executions)
      connection.create_table :solid_queue_claimed_executions do |t|
        t.datetime :created_at, null: false
        t.bigint :job_id, null: false
        t.bigint :process_id
      end
    end

    unless connection.table_exists?(:solid_queue_blocked_executions)
      connection.create_table :solid_queue_blocked_executions do |t|
        t.string :concurrency_key, null: false
        t.datetime :created_at, null: false
        t.datetime :expires_at, null: false
        t.bigint :job_id, null: false
        t.integer :priority, default: 0, null: false
        t.string :queue_name, null: false
      end
    end

    unless connection.table_exists?(:solid_queue_pauses)
      connection.create_table :solid_queue_pauses do |t|
        t.datetime :created_at, null: false
        t.string :queue_name, null: false
      end
    end

    unless connection.table_exists?(:solid_queue_processes)
      connection.create_table :solid_queue_processes do |t|
        t.datetime :created_at, null: false
        t.string :hostname
        t.string :kind, null: false
        t.datetime :last_heartbeat_at, null: false
        t.text :metadata
        t.string :name, null: false
        t.integer :pid, null: false
        t.bigint :supervisor_id
      end
    end

    unless connection.table_exists?(:solid_queue_ready_executions)
      connection.create_table :solid_queue_ready_executions do |t|
        t.datetime :created_at, null: false
        t.bigint :job_id, null: false
        t.integer :priority, default: 0, null: false
        t.string :queue_name, null: false
      end
    end

    unless connection.table_exists?(:solid_queue_failed_executions)
      connection.create_table :solid_queue_failed_executions do |t|
        t.datetime :created_at, null: false
        t.text :error
        t.bigint :job_id, null: false
      end
    end

    unless connection.table_exists?(:solid_queue_recurring_tasks)
      connection.create_table :solid_queue_recurring_tasks do |t|
        t.text :arguments
        t.string :class_name
        t.string :command, limit: 2048
        t.datetime :created_at, null: false
        t.text :description
        t.string :key, null: false
        t.integer :priority, default: 0
        t.string :queue_name
        t.string :schedule, null: false
        t.boolean :static, default: true, null: false
        t.datetime :updated_at, null: false
      end
    end

    unless connection.table_exists?(:solid_queue_recurring_executions)
      connection.create_table :solid_queue_recurring_executions do |t|
        t.datetime :created_at, null: false
        t.bigint :job_id, null: false
        t.datetime :run_at, null: false
        t.string :task_key, null: false
      end
    end

    [
      SolidQueue::Job,
      SolidQueue::ClaimedExecution,
      SolidQueue::BlockedExecution,
      SolidQueue::ReadyExecution,
      SolidQueue::FailedExecution,
      SolidQueue::Process,
      SolidQueue::Pause,
      SolidQueue::RecurringTask,
      SolidQueue::RecurringExecution
    ].each(&:reset_column_information)
  end

  def clear_solid_queue_test_tables!
    connection = ActiveRecord::Base.connection
    %i[
      solid_queue_recurring_executions
      solid_queue_recurring_tasks
      solid_queue_failed_executions
      solid_queue_ready_executions
      solid_queue_pauses
      solid_queue_blocked_executions
      solid_queue_claimed_executions
      solid_queue_jobs
      solid_queue_processes
    ].each do |table|
      connection.delete("DELETE FROM #{connection.quote_table_name(table)}") if connection.table_exists?(table)
    end
  end

  def drop_solid_queue_test_tables!
    connection = ActiveRecord::Base.connection
    %i[
      solid_queue_recurring_executions
      solid_queue_recurring_tasks
      solid_queue_failed_executions
      solid_queue_ready_executions
      solid_queue_claimed_executions
      solid_queue_pauses
      solid_queue_blocked_executions
      solid_queue_processes
      solid_queue_jobs
    ].each do |table|
      connection.drop_table(table) if connection.table_exists?(table)
    end
  end
end

RSpec.configure do |config|
  config.include SolidQueueTestTables
end
