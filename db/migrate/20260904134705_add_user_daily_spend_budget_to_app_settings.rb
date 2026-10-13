class AddUserDailySpendBudgetToAppSettings < ActiveRecord::Migration[8.1]
  # Add the column in its original unlimited state; later migrations may tighten
  # the fresh-instance default without rewriting explicit operator choices.
  def up
    return if column_exists?(:app_settings, :user_daily_spend_budget_usd)

    add_column :app_settings, :user_daily_spend_budget_usd, :integer, default: 0, null: false
  end

  def down
    remove_column :app_settings, :user_daily_spend_budget_usd if column_exists?(:app_settings, :user_daily_spend_budget_usd)
  end
end
