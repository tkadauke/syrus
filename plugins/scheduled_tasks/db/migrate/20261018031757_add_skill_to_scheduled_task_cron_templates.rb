class AddSkillToScheduledTaskCronTemplates < ActiveRecord::Migration[8.1]
  def change
    add_column :scheduled_task_cron_templates, :skill_name, :string unless column_exists?(:scheduled_task_cron_templates, :skill_name)
    add_column :scheduled_task_cron_templates, :skill_args, :json unless column_exists?(:scheduled_task_cron_templates, :skill_args)
    change_column_null :scheduled_task_cron_templates, :prompt, true
  end
end
