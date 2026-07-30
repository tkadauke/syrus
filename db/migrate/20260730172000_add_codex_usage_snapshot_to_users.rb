class AddCodexUsageSnapshotToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :codex_usage_status, :string
    add_column :users, :codex_usage_observed_at, :datetime
    add_column :users, :codex_usage_snapshot, :json
  end
end
