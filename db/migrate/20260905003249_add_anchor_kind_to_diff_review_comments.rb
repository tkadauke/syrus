class AddAnchorKindToDiffReviewComments < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:diff_review_comments, :anchor_kind)
      add_column :diff_review_comments, :anchor_kind, :string, default: "line", null: false
    end
    change_column_null :diff_review_comments, :path, true
    change_column_null :diff_review_comments, :side, true
  end

  def down
    change_column_null :diff_review_comments, :side, false
    change_column_null :diff_review_comments, :path, false
    remove_column :diff_review_comments, :anchor_kind if column_exists?(:diff_review_comments, :anchor_kind)
  end
end
