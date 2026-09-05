class RenameCronTemplatesToScheduledTaskCronTemplates < ActiveRecord::Migration[8.1]
  # A plugin's tables carry its namespace, so the boundary between core tables
  # and plugin tables is visible in the schema and not only in the code.
  # `scheduled_tasks` already matched; `cron_templates` did not.
  def up
    return if table_exists?(:scheduled_task_cron_templates)

    rename_table :cron_templates, :scheduled_task_cron_templates if table_exists?(:cron_templates)
  end

  def down
    return if table_exists?(:cron_templates)

    rename_table :scheduled_task_cron_templates, :cron_templates if table_exists?(:scheduled_task_cron_templates)
  end
end
