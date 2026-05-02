class AddIssueMetadataToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :issue_title, :string
    add_column :jobs, :issue_body, :text
  end
end
