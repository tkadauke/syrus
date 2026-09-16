module Metrics
  # The only place that touches `ProviderSession` and `AutoRetryAttempt` for
  # the maintenance/pruner metric group. Both are ordinary ActiveRecord
  # tables (unlike solid_queue_*, see CLAUDE.md), so this class is exercised
  # directly with real records in specs -- Metrics::QueueSource owns the
  # Solid Queue-backed half of this metric group
  # (`recurring_job_last_success_at`), the same split Metrics::LandingSampler
  # already uses between Metrics::LandingSource and Metrics::QueueSource.
  class MaintenanceSource
    # `LENGTH()` is byte length on MySQL for a non-binary text column; this is
    # an approximate operational gauge (the incident it guards against was a
    # 6 GB table), not a byte-exact accounting figure.
    def provider_sessions_bytes
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
  end
end
