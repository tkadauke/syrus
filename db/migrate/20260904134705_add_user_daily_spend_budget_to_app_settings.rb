class AddUserDailySpendBudgetToAppSettings < ActiveRecord::Migration[8.1]
  # workflow-engine-v3 C1: resource isolation between users. Zero keeps
  # today's behavior exactly -- no per-user budget, only the global controls.
  def up
    return if column_exists?(:app_settings, :user_daily_spend_budget_usd)

    add_column :app_settings, :user_daily_spend_budget_usd, :integer, default: 0, null: false
  end

  def down
    remove_column :app_settings, :user_daily_spend_budget_usd if column_exists?(:app_settings, :user_daily_spend_budget_usd)
  end
end
