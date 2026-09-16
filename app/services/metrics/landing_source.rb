module Metrics
  # The only place that touches Job/Run/Step for landing-queue and
  # run-throughput metrics.
  #
  # Unlike Metrics::QueueSource, these are ordinary ActiveRecord tables that
  # exist in the test database (see CLAUDE.md), so this class is exercised
  # directly rather than through a fake in specs.
  #
  # Windowed reads only -- callers pass a `[after, through)` boundary so a
  # sample tick instruments each terminal Run/landed Job exactly once instead
  # of re-scanning the whole table every time.
  class LandingSource
    LANDED_CLOSURE_REASONS = %w[ pr_merged external_pr_merged ].freeze

    def job_state_counts
      Job.group(:state).count
    end

    # `LandingQueueProcessor` already recomputes and persists
    # `landing_queue_blocked_reason` on every approved/landing Job every 30
    # seconds (see LandingQueueProcessor#persist_snapshot!). Reading that
    # column is a cheap, indexed query; recomputing blockage_for for every
    # Job here would be the exact "aggregate query on the metrics path" this
    # sampler exists to avoid.
    #
    # `blocked_reason` is stored as `{"key" => ..., "params" => {...}}` --
    # only `key` is a bounded, closed-set value (see
    # LandingQueueProcessor#blockage_for); `params` can carry a Job slug and
    # must never become a label.
    def landing_queue_blocked_reason_counts
      Job.landing_queue.pluck(:landing_queue_blocked_reason)
         .group_by { |reason| blocked_reason_key(reason) }
         .transform_values(&:count)
    end

    # Runs that reached a terminal state in `[after, through)`, with enough to
    # tag syrus_runs_total{state,trigger_kind} and observe
    # syrus_run_duration_seconds{step_kind}. Left-joined to step because
    # Run#step_id is optional; a Run with no step still counts toward
    # syrus_runs_total, it just cannot contribute a duration observation.
    def finished_runs(after:, through:)
      Run.terminal
         .where(finished_at: after...through)
         .left_joins(:step)
         .pluck("runs.state", "runs.trigger_kind", "runs.started_at", "runs.finished_at", "steps.kind")
    end

    # Jobs that landed (their PR reached the base branch) in `[after,
    # through)`, for syrus_jobs_landed_total and syrus_time_to_land_seconds.
    def landed_jobs(after:, through:)
      Job.where(closure_reason: LANDED_CLOSURE_REASONS)
         .where(finished_at: after...through)
         .pluck(:created_at, :finished_at)
    end

    private

    def blocked_reason_key(reason)
      return "none" if reason.blank?

      key = reason.is_a?(Hash) ? (reason["key"] || reason[:key]) : nil
      key.presence || "unknown"
    end
  end
end
