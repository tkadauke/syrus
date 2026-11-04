class AddReviewerTargetSnapshotToReviewEvidences < ActiveRecord::Migration[8.1]
  def up
    add_column :review_evidences, :reviewer_target_snapshot, :json unless column_exists?(:review_evidences, :reviewer_target_snapshot)
  end

  def down
    remove_column :review_evidences, :reviewer_target_snapshot if column_exists?(:review_evidences, :reviewer_target_snapshot)
  end
end
