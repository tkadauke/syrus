class AddBugFixToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :bug_fix, :boolean, default: false, null: false unless column_exists?(:jobs, :bug_fix)
  end

  def down
    remove_column :jobs, :bug_fix if column_exists?(:jobs, :bug_fix)
  end
end
