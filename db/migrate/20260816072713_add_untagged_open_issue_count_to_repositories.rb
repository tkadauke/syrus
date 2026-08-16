class AddUntaggedOpenIssueCountToRepositories < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:repositories, :untagged_open_issue_count)
      add_column :repositories, :untagged_open_issue_count, :integer, default: 0, null: false
    end
    unless column_exists?(:repositories, :untagged_open_issues_checked_at)
      add_column :repositories, :untagged_open_issues_checked_at, :datetime
    end
  end
end
