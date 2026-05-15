class DropRecurringTasks < ActiveRecord::Migration[8.1]
  class MigrationRecurringTask < ActiveRecord::Base
    self.table_name = "recurring_tasks"
  end

  class MigrationScheduledTask < ActiveRecord::Base
    self.table_name = "scheduled_tasks"
  end

  # RecurringTask was a stripped-down sibling of ScheduledTask used only
  # by the chat agent's `schedule_recurring` MCP tool. Folded back into
  # ScheduledTask (chat tool now creates ScheduledTask with kind: cron),
  # so the dedicated table goes away after preserving existing definitions.
  def up
    return unless table_exists?(:recurring_tasks)

    MigrationRecurringTask.reset_column_information
    MigrationScheduledTask.reset_column_information

    say_with_time "Migrating RecurringTask rows to ScheduledTask" do
      MigrationRecurringTask.find_each do |task|
        MigrationScheduledTask.create!(
          user_id: task.user_id,
          repository_id: task.repository_id,
          kind: "cron",
          state: task.enabled? ? "scheduled" : "paused",
          name: task.label,
          prompt: task.prompt,
          cron_expression: task.cron_expression,
          minute_offset: minute_offset_for(task.cron_expression),
          pr_pileup_policy: "skip",
          consecutive_failure_count: 0,
          created_at: task.created_at,
          updated_at: task.updated_at
        )
      end
    end

    drop_table :recurring_tasks
  end

  def down
    create_table :recurring_tasks do |t|
      t.references :repository, null: false, foreign_key: false
      t.references :user,       null: false, foreign_key: false
      t.string  :label,           null: false
      t.string  :cron_expression, null: false
      t.text    :prompt,          null: false
      t.datetime :next_fire_at,   null: false
      t.boolean :enabled, default: true, null: false
      t.timestamps
    end
    add_index :recurring_tasks, [ :enabled, :next_fire_at ]
  end

  private

  def minute_offset_for(cron_expression)
    minute = cron_expression.to_s.split(/\s+/).first
    return minute.to_i if minute&.match?(/\A(?:[0-9]|[1-5][0-9])\z/)

    0
  end
end
