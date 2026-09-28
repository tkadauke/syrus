class AddAnchorToPrReviewComments < ActiveRecord::Migration[8.1]
  def up
    add_column :pr_review_comments, :path, :string unless column_exists?(:pr_review_comments, :path)
    add_column :pr_review_comments, :side, :string unless column_exists?(:pr_review_comments, :side)
    add_column :pr_review_comments, :line, :integer unless column_exists?(:pr_review_comments, :line)
    add_column :pr_review_comments, :start_line, :integer unless column_exists?(:pr_review_comments, :start_line)
    add_column :pr_review_comments, :original_line, :integer unless column_exists?(:pr_review_comments, :original_line)
    unless column_exists?(:pr_review_comments, :original_start_line)
      add_column :pr_review_comments, :original_start_line, :integer
    end
  end

  def down
    remove_column :pr_review_comments, :original_start_line if column_exists?(:pr_review_comments, :original_start_line)
    remove_column :pr_review_comments, :original_line if column_exists?(:pr_review_comments, :original_line)
    remove_column :pr_review_comments, :start_line if column_exists?(:pr_review_comments, :start_line)
    remove_column :pr_review_comments, :line if column_exists?(:pr_review_comments, :line)
    remove_column :pr_review_comments, :side if column_exists?(:pr_review_comments, :side)
    remove_column :pr_review_comments, :path if column_exists?(:pr_review_comments, :path)
  end
end
