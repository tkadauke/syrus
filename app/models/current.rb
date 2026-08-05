class Current < ActiveSupport::CurrentAttributes
  attribute :session,
            :api_user,
            :feature_enabled_cache,
            :provider_availability_cache,
            :operational_log_indexing_enabled,
            :performance_logging_enabled,
            :performance_request_context,
            :performance_sql_count,
            :performance_sql_duration_ms,
            :performance_slow_sql_count,
            :performance_sql_fingerprints

  def user
    api_user || session&.user
  end
end
