class AddBranchDeletedAtToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :branch_deleted_at, :datetime unless column_exists?(:jobs, :branch_deleted_at)
  end

  def down
    remove_column :jobs, :branch_deleted_at if column_exists?(:jobs, :branch_deleted_at)
  end
end
