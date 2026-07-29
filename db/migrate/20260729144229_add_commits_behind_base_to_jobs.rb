class AddCommitsBehindBaseToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :commits_behind_base, :integer unless column_exists?(:jobs, :commits_behind_base)
  end

  def down
    remove_column :jobs, :commits_behind_base if column_exists?(:jobs, :commits_behind_base)
  end
end
