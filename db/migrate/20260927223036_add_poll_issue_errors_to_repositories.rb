class AddPollIssueErrorsToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :poll_issue_errors, :json unless column_exists?(:repositories, :poll_issue_errors)
  end
end
