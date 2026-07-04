class AddLastSeenForkReviewCommentAtToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :last_seen_fork_review_comment_at, :datetime unless column_exists?(:jobs, :last_seen_fork_review_comment_at)
  end

  def down
    remove_column :jobs, :last_seen_fork_review_comment_at if column_exists?(:jobs, :last_seen_fork_review_comment_at)
  end
end
