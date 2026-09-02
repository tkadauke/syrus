class AddRecentStatsToTestIdentities < ActiveRecord::Migration[8.1]
  def change
    add_column :test_identities, :recent_sample_count, :integer, null: false, default: 0
    add_column :test_identities, :recent_failed_count, :integer, null: false, default: 0
    add_column :test_identities, :recent_passed_count, :integer, null: false, default: 0
    add_column :test_identities, :recent_avg_duration_ms, :integer
  end
end
