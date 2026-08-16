class AddTargetBranchToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :target_branch, :string unless column_exists?(:jobs, :target_branch)
  end
end
