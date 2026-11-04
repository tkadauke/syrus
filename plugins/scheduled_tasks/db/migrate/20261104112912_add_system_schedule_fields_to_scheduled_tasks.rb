class AddSystemScheduleFieldsToScheduledTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :scheduled_tasks, :system_key, :string unless column_exists?(:scheduled_tasks, :system_key)
    add_column :scheduled_tasks, :last_journaled_on, :date unless column_exists?(:scheduled_tasks, :last_journaled_on)
    add_column :scheduled_tasks, :last_system_result, :string unless column_exists?(:scheduled_tasks, :last_system_result)
    add_column :scheduled_tasks, :last_system_result_on, :date unless column_exists?(:scheduled_tasks, :last_system_result_on)
    add_column :scheduled_tasks, :last_system_result_reason, :string unless column_exists?(:scheduled_tasks, :last_system_result_reason)
    add_column :scheduled_tasks, :system_result_history, :json unless column_exists?(:scheduled_tasks, :system_result_history)
    unless index_exists?(:scheduled_tasks, %i[coworker_id system_key], name: "index_scheduled_tasks_on_coworker_and_system_key")
      add_index :scheduled_tasks, %i[coworker_id system_key], unique: true,
                name: "index_scheduled_tasks_on_coworker_and_system_key"
    end
  end
end
