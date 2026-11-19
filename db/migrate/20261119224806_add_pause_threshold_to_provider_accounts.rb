class AddPauseThresholdToProviderAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :provider_accounts, :proactive_pause_threshold, :decimal,
      precision: 5, scale: 2, if_not_exists: true
  end
end
