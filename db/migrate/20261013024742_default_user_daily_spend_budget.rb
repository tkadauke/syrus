class DefaultUserDailySpendBudget < ActiveRecord::Migration[8.1]
  DEFAULT_USER_DAILY_SPEND_BUDGET_USD = 20

  def up
    return unless table_exists?(:app_settings)
    return unless column_exists?(:app_settings, :user_daily_spend_budget_usd)

    change_column_default :app_settings,
                          :user_daily_spend_budget_usd,
                          from: 0,
                          to: DEFAULT_USER_DAILY_SPEND_BUDGET_USD
  end

  def down
    return unless table_exists?(:app_settings)
    return unless column_exists?(:app_settings, :user_daily_spend_budget_usd)

    change_column_default :app_settings,
                          :user_daily_spend_budget_usd,
                          from: DEFAULT_USER_DAILY_SPEND_BUDGET_USD,
                          to: 0
  end
end
