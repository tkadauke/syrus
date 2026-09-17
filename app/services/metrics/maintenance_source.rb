module Metrics
  # The only place that touches `ProviderSession` and `AutoRetryAttempt` for
  # the maintenance/pruner metric group. Both are ordinary ActiveRecord
  # tables (unlike solid_queue_*, see CLAUDE.md), so this class is exercised
  # directly with real records in specs -- Metrics::QueueSource owns the
  # Solid Queue-backed half of this metric group
  # (`recurring_job_last_success_at`), the same split Metrics::LandingSampler
  # already uses between Metrics::LandingSource and Metrics::QueueSource.
  class MaintenanceSource
    def provider_sessions_bytes
      return mysql_provider_sessions_table_bytes if mysql?

      ProviderSession.sum(Arel.sql("LENGTH(transcript_jsonl)")).to_i
    end

    def provider_sessions_rows
      ProviderSession.count
    end

    # Attempts that settled (either performed or skipped) in `[after,
    # through)`, for syrus_auto_retry_attempts_total. Windowed on `updated_at`
    # rather than `created_at`: an attempt's `skipped_reason` is often set
    # well after creation (AutoRetryJob runs at `scheduled_at`, up to an hour
    # later), and `updated_at` only moves once more, when the attempt settles
    # -- see AutoRetryJob.
    def settled_auto_retry_attempts(after:, through:)
      AutoRetryAttempt
        .where(updated_at: after...through)
        .where("performed_at IS NOT NULL OR skipped_reason IS NOT NULL")
        .pluck(:skipped_reason)
    end

    private

    # MySQL has to read every transcript_jsonl value to answer
    # `SUM(LENGTH(transcript_jsonl))`; on production-sized LONGTEXT rows that
    # made the global metrics tick take minutes. The dashboard only needs the
    # growth signal that warned us about the 6 GB incident, so use InnoDB's
    # table-size estimate instead of scanning the table.
    def mysql_provider_sessions_table_bytes
      ProviderSession.connection.select_value(<<~SQL.squish).to_i
        SELECT COALESCE(DATA_LENGTH, 0) + COALESCE(INDEX_LENGTH, 0)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = 'provider_sessions'
        LIMIT 1
      SQL
    end

    def mysql?
      ProviderSession.connection.adapter_name.to_s.downcase.include?("mysql")
    end
  end
end
