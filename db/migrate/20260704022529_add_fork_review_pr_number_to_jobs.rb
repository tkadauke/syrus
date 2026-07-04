class AddForkReviewPrNumberToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :fork_review_pr_number, :integer unless column_exists?(:jobs, :fork_review_pr_number)
  end

  def down
    remove_column :jobs, :fork_review_pr_number if column_exists?(:jobs, :fork_review_pr_number)
  end
end
