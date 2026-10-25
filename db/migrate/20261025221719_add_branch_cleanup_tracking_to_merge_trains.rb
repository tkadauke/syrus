class AddBranchCleanupTrackingToMergeTrains < ActiveRecord::Migration[8.1]
  def change
    add_column :merge_trains, :branch_cleanup_attempted_at, :datetime unless column_exists?(:merge_trains, :branch_cleanup_attempted_at)
    add_column :merge_trains, :branch_deleted_at, :datetime unless column_exists?(:merge_trains, :branch_deleted_at)
    columns = [ :state, :branch_deleted_at, :branch_cleanup_attempted_at, :finished_at ]
    index_name = "idx_merge_trains_branch_cleanup_candidates"
    unless index_exists?(:merge_trains, columns, name: index_name)
      add_index :merge_trains, columns, name: index_name
    end
  end
end
