class RemoveUserDailySpendBudgetFromAppSettings < ActiveRecord::Migration[8.1]
  SPEND_WINDOW_INDEX = "idx_runs_spending_user_finished_window"
  SPEND_WINDOW_COLUMNS = [ :user_id, :finished_at, :cost_usd ].freeze

  def up
    remove_column :app_settings, :user_daily_spend_budget_usd if column_exists?(:app_settings, :user_daily_spend_budget_usd)
    remove_index :runs, name: SPEND_WINDOW_INDEX if index_exists?(:runs, SPEND_WINDOW_COLUMNS, name: SPEND_WINDOW_INDEX)
  end

  def down
    unless column_exists?(:app_settings, :user_daily_spend_budget_usd)
      add_column :app_settings, :user_daily_spend_budget_usd, :integer, default: 20, null: false
    end

    unless index_exists?(:runs, SPEND_WINDOW_COLUMNS, name: SPEND_WINDOW_INDEX)
      add_index :runs, SPEND_WINDOW_COLUMNS, name: SPEND_WINDOW_INDEX
    end
  end
end
