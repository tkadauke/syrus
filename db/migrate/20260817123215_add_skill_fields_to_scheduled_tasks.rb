class AddSkillFieldsToScheduledTasks < ActiveRecord::Migration[8.1]
  def up
    add_column :scheduled_tasks, :skill_name, :string unless column_exists?(:scheduled_tasks, :skill_name)
    add_column :scheduled_tasks, :skill_args, :json unless column_exists?(:scheduled_tasks, :skill_args)
    change_column_null :scheduled_tasks, :prompt, true
  end

  def down
    change_column_null :scheduled_tasks, :prompt, false
    remove_column :scheduled_tasks, :skill_args if column_exists?(:scheduled_tasks, :skill_args)
    remove_column :scheduled_tasks, :skill_name if column_exists?(:scheduled_tasks, :skill_name)
  end
end
