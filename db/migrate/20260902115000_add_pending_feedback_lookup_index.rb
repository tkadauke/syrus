class AddPendingFeedbackLookupIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :pr_review_comments,
      [ :job_id, :actionable, :attributed_to, :handling_state, :comment_created_at, :id ],
      name: "idx_pr_review_comments_pending_feedback",
      if_not_exists: true
  end
end
