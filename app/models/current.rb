class Current < ActiveSupport::CurrentAttributes
  attribute :session,
            :api_user,
            :feature_enabled_cache,
            :provider_availability_cache,
            :performance_logging_enabled,
            :performance_sql_count,
            :performance_sql_duration_ms,
            :performance_slow_sql_count

  def user
    api_user || session&.user
  end
end
