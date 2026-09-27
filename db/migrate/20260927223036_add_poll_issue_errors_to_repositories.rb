class AddPollIssueErrorsToRepositories < ActiveRecord::Migration[8.1]
  def change
    add_column :repositories, :poll_issue_errors, :json, if_not_exists: true
  end
end
