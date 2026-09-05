class AddParentToDiffReviewComments < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:diff_review_comments, :parent_id)
      add_reference :diff_review_comments, :parent, null: true, foreign_key: { to_table: :diff_review_comments }
    end
  end
end
