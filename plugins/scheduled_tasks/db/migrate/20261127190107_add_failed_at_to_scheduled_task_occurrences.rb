class AddFailedAtToScheduledTaskOccurrences < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:scheduled_task_occurrences, :failed_at)

    add_column :scheduled_task_occurrences, :failed_at, :datetime, precision: 6
  end

  def down
    remove_column :scheduled_task_occurrences, :failed_at if column_exists?(:scheduled_task_occurrences, :failed_at)
  end
end
