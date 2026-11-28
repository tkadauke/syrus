class CreateScheduledTaskOccurrences < ActiveRecord::Migration[8.1]
  def up
    create_table :scheduled_task_occurrences, if_not_exists: true do |t|
      t.integer :scheduled_task_id, null: false
      t.datetime :due_at, null: false
      t.integer :job_id
      t.datetime :completed_at
      t.timestamps
    end

    unless index_exists?(:scheduled_task_occurrences, %i[scheduled_task_id due_at], unique: true)
      add_index :scheduled_task_occurrences, %i[scheduled_task_id due_at], unique: true,
                name: "index_scheduled_task_occurrences_on_task_and_due_at"
    end
    add_index :scheduled_task_occurrences, :job_id, unique: true unless index_exists?(:scheduled_task_occurrences, :job_id)
  end

  def down
    drop_table :scheduled_task_occurrences, if_exists: true
  end
end
