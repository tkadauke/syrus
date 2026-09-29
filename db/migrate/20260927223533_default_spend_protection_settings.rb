class DefaultSpendProtectionSettings < ActiveRecord::Migration[8.1]
  DEFAULT_MAX_CONCURRENT_AGENT_RUNS = 3

  def up
    return unless table_exists?(:app_settings)

    if column_exists?(:app_settings, :max_concurrent_agent_runs)
      change_column_default :app_settings,
                            :max_concurrent_agent_runs,
                            from: 0,
                            to: DEFAULT_MAX_CONCURRENT_AGENT_RUNS
    end
  end

  def down
    return unless table_exists?(:app_settings)

    if column_exists?(:app_settings, :max_concurrent_agent_runs)
      change_column_default :app_settings,
                            :max_concurrent_agent_runs,
                            from: DEFAULT_MAX_CONCURRENT_AGENT_RUNS,
                            to: 0
    end
  end
end
