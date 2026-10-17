class RemoveUserDailySpendBudgetFromAppSettings < ActiveRecord::Migration[8.1]
  def up
    remove_column :app_settings, :user_daily_spend_budget_usd if column_exists?(:app_settings, :user_daily_spend_budget_usd)
  end

  def down
    return if column_exists?(:app_settings, :user_daily_spend_budget_usd)

    add_column :app_settings, :user_daily_spend_budget_usd, :integer, default: 20, null: false
  end
end
