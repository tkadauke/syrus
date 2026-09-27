class DefaultSpendProtectionSettings < ActiveRecord::Migration[8.1]
  DEFAULT_MAX_CONCURRENT_AGENT_RUNS = 3
  DEFAULT_USER_DAILY_SPEND_BUDGET_USD = 10

  def up
    return unless table_exists?(:app_settings)

    if column_exists?(:app_settings, :max_concurrent_agent_runs)
      change_column_default :app_settings,
                            :max_concurrent_agent_runs,
                            from: 0,
                            to: DEFAULT_MAX_CONCURRENT_AGENT_RUNS
      execute <<~SQL.squish
        UPDATE app_settings
        SET max_concurrent_agent_runs = #{DEFAULT_MAX_CONCURRENT_AGENT_RUNS}
        WHERE max_concurrent_agent_runs = 0
      SQL
    end

    return unless column_exists?(:app_settings, :user_daily_spend_budget_usd)

    change_column_default :app_settings,
                          :user_daily_spend_budget_usd,
                          from: 0,
                          to: DEFAULT_USER_DAILY_SPEND_BUDGET_USD
    execute <<~SQL.squish
      UPDATE app_settings
      SET user_daily_spend_budget_usd = #{DEFAULT_USER_DAILY_SPEND_BUDGET_USD}
      WHERE user_daily_spend_budget_usd = 0
    SQL
  end

  def down
    return unless table_exists?(:app_settings)

    if column_exists?(:app_settings, :max_concurrent_agent_runs)
      change_column_default :app_settings,
                            :max_concurrent_agent_runs,
                            from: DEFAULT_MAX_CONCURRENT_AGENT_RUNS,
                            to: 0
    end

    return unless column_exists?(:app_settings, :user_daily_spend_budget_usd)

    change_column_default :app_settings,
                          :user_daily_spend_budget_usd,
                          from: DEFAULT_USER_DAILY_SPEND_BUDGET_USD,
                          to: 0
  end
end
