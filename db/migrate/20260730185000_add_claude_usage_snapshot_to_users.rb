class AddClaudeUsageSnapshotToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :claude_usage_status, :string
    add_column :users, :claude_usage_observed_at, :datetime
    add_column :users, :claude_usage_snapshot, :json
  end
end
