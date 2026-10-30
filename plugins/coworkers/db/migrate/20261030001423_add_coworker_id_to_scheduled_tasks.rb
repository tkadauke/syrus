class AddCoworkerIdToScheduledTasks < ActiveRecord::Migration[8.1]
  def up
    add_reference :scheduled_tasks, :coworker, null: true, foreign_key: true, index: true unless column_exists?(:scheduled_tasks, :coworker_id)
  end

  def down
    remove_reference :scheduled_tasks, :coworker, foreign_key: true if column_exists?(:scheduled_tasks, :coworker_id)
  end
end
