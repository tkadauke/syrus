class AddSystemScheduleFieldsToScheduledTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :scheduled_tasks, :system_key, :string
    add_column :scheduled_tasks, :last_journaled_on, :date
    add_column :scheduled_tasks, :last_system_result, :string
    add_column :scheduled_tasks, :last_system_result_on, :date
    add_column :scheduled_tasks, :last_system_result_reason, :string
    add_column :scheduled_tasks, :system_result_history, :json
    add_index :scheduled_tasks, %i[coworker_id system_key], unique: true,
              name: "index_scheduled_tasks_on_coworker_and_system_key"
  end
end
