class AddBranchCleanupAttemptedAtToJobs < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_jobs_branch_cleanup_candidates"

  def up
    add_column :jobs, :branch_cleanup_attempted_at, :datetime unless column_exists?(:jobs, :branch_cleanup_attempted_at)
    add_index :jobs, [ :state, :branch_deleted_at, :branch_cleanup_attempted_at, :finished_at ], name: INDEX_NAME unless index_exists?(:jobs, name: INDEX_NAME)
  end

  def down
    remove_index :jobs, name: INDEX_NAME if index_exists?(:jobs, name: INDEX_NAME)
    remove_column :jobs, :branch_cleanup_attempted_at if column_exists?(:jobs, :branch_cleanup_attempted_at)
  end
end
