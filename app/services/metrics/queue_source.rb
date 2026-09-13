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
  end
end
