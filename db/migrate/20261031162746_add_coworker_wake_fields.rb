class AddCoworkerWakeFields < ActiveRecord::Migration[8.1]
  def up
    added_after_run = !column_exists?(:scheduled_tasks, :after_run)
    add_column :scheduled_tasks, :after_run, :string, default: "quiet", null: false if added_after_run
    add_column :runs, :coworker_wake_enqueued_at, :datetime unless column_exists?(:runs, :coworker_wake_enqueued_at)

    if added_after_run
      execute <<~SQL.squish
        UPDATE scheduled_tasks
        SET after_run = 'wake'
        WHERE coworker_id IS NOT NULL
      SQL
    end
  end

  def down
    remove_column :runs, :coworker_wake_enqueued_at if column_exists?(:runs, :coworker_wake_enqueued_at)
    remove_column :scheduled_tasks, :after_run if column_exists?(:scheduled_tasks, :after_run)
  end
end
