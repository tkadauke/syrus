module Metrics
  # The only place that touches the Solid Queue tables for metrics.
  #
  # Split out from QueueSampler so the sampler's logic -- caching, gauge
  # setting, staleness, degradation when a query fails -- is testable without a
  # queue database. Tests run single-database and the solid_queue_* tables do
  # not exist there (see CLAUDE.md), so anything that needs them has to live
  # behind a seam. This class is deliberately thin: it is the part that cannot
  # be tested here, so there should be as little of it as possible.
  #
  # Each reader degrades independently. One unreachable table should cost its
  # own gauge, not the whole sample.
  class QueueSource
    FAILED_CLASS_LIMIT = 15

    def ready_counts
      SolidQueue::ReadyExecution.group(:queue_name).count
    end

    # The timestamp, not the age: the sampler converts it, so the conversion is
    # testable and this stays a pure read.
    def oldest_ready_at
      SolidQueue::ReadyExecution.group(:queue_name).minimum(:created_at)
    end

    def claimed_counts
      SolidQueue::ClaimedExecution.joins(:job).group("solid_queue_jobs.queue_name").count
    end

    def blocked_count
      SolidQueue::BlockedExecution.count
    end

    # Top N only. `job_class` is bounded in principle but long in practice, and
    # the failures worth alerting on are always the largest few.
    def failed_counts
      SolidQueue::FailedExecution
        .joins(:job)
        .group("solid_queue_jobs.class_name")
        .order(Arel.sql("COUNT(*) DESC"))
        .limit(FAILED_CLASS_LIMIT)
        .count
    end

    # A job row that is not finished and has no execution row of any kind is
    # reachable by nothing: no worker will claim it, and
    # `clear_solid_queue_finished_jobs` skips it because it never finished. They
    # accumulate silently and bloat the table every dispatcher scans -- 553,671
    # of them in production when this was written, 84% of that table.
    def orphaned_rows
      SolidQueue::Job
        .where(finished_at: nil)
        .where.missing(:ready_execution, :claimed_execution, :failed_execution,
                       :scheduled_execution, :blocked_execution)
        .count
    end

    # Table-level companion to orphaned_rows: every row in solid_queue_jobs,
    # regardless of state. A pruner silently stopping shows up here as
    # unbounded growth before it shows up anywhere else.
    def table_rows
      SolidQueue::Job.count
    end

    # Jobs that finished in `[after, through)`, for syrus_queue_completed_total
    # -- the numerator of the "queue starved" alert
    # (rate(syrus_queue_completed_total[5m]) == 0 and syrus_queue_ready_count > 0).
    # Windowed rather than a running total because finished rows are pruned by
    # clear_solid_queue_finished_jobs, so there is no stable all-time count to
    # read back.
    def completed_count(after:, through:)
      SolidQueue::Job.where(finished_at: after...through).count
    end
  end
end
