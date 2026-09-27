class AddLinkedOpenPrCheckedAtToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :linked_open_pr_checked_at, :datetime unless column_exists?(:jobs, :linked_open_pr_checked_at)
  end
end
