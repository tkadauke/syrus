class AddPauseThresholdToProviderAccounts < ActiveRecord::Migration[8.1]
  def up
    add_column :provider_accounts, :proactive_pause_threshold, :decimal, precision: 5, scale: 2 unless column_exists?(:provider_accounts, :proactive_pause_threshold)
  end

  def down
    remove_column :provider_accounts, :proactive_pause_threshold if column_exists?(:provider_accounts, :proactive_pause_threshold)
  end
end
