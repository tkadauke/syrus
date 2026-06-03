class AddExecutionOwnerToWorkflowsAndRuns < ActiveRecord::Migration[8.1]
  def up
    add_column :workflows, :user_id, :integer unless column_exists?(:workflows, :user_id)
    add_index :workflows, :user_id unless index_exists?(:workflows, :user_id)
    add_foreign_key :workflows, :users, column: :user_id unless foreign_key_exists?(:workflows, :users, column: :user_id)

    add_column :runs, :user_id, :integer unless column_exists?(:runs, :user_id)
    add_index :runs, :user_id unless index_exists?(:runs, :user_id)
    add_foreign_key :runs, :users, column: :user_id unless foreign_key_exists?(:runs, :users, column: :user_id)

    execute <<~SQL.squish
      UPDATE workflows
      SET user_id = (
        SELECT jobs.user_id
        FROM jobs
        WHERE jobs.id = workflows.job_id
      )
      WHERE user_id IS NULL
    SQL

    execute <<~SQL.squish
      UPDATE runs
      SET user_id = (
        SELECT jobs.user_id
        FROM jobs
        WHERE jobs.id = runs.job_id
      )
      WHERE user_id IS NULL
    SQL

    change_column_null :workflows, :user_id, false if column_exists?(:workflows, :user_id)
    change_column_null :runs, :user_id, false if column_exists?(:runs, :user_id)
  end

  def down
    if column_exists?(:runs, :user_id)
      remove_foreign_key :runs, column: :user_id if foreign_key_exists?(:runs, :users, column: :user_id)
      remove_index :runs, :user_id if index_exists?(:runs, :user_id)
      remove_column :runs, :user_id
    end

    if column_exists?(:workflows, :user_id)
      remove_foreign_key :workflows, column: :user_id if foreign_key_exists?(:workflows, :users, column: :user_id)
      remove_index :workflows, :user_id if index_exists?(:workflows, :user_id)
      remove_column :workflows, :user_id
    end
  end
end
