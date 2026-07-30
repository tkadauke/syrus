class AddCodexUsageSnapshotToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :codex_usage_status, :string unless column_exists?(:users, :codex_usage_status)
    add_column :users, :codex_usage_observed_at, :datetime unless column_exists?(:users, :codex_usage_observed_at)
    add_column :users, :codex_usage_snapshot, :json unless column_exists?(:users, :codex_usage_snapshot)
  end
end
