class Current < ActiveSupport::CurrentAttributes
  attribute :session,
            :api_user,
            :feature_enabled_cache,
            :provider_availability_cache,
            :operational_log_indexing_enabled,
            :suppress_operational_log_index_enqueue,
            :performance_logging_enabled,
            :performance_request_context,
            :performance_sql_count,
            :performance_sql_duration_ms,
            :performance_slow_sql_count,
            :performance_sql_fingerprints,
            :performance_phase_stack

  def user
    api_user || session&.user
  end
end
