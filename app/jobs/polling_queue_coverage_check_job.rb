# A deployment's queue-config split (config/queue.home.yml vs
# config/queue.compute.yml, or a hand-rolled variant selected per pod via
# SOLID_QUEUE_CONFIG) can accidentally omit the `polling` queue from every
# worker tier. When that happens, nothing in the fleet ever runs
# PollAllRepositoriesJob/PollAllPullRequestsJob/PollAllMergeStatesJob/etc —
# GitHub issue ingestion, PR feedback, and merge-state checks all go
# silently dead — and, as a direct downstream symptom,
# GitHistory::RelayServer.ensure_running! (gated on WorkerQueueTopology the
# same way) never starts anywhere and RepositoryBareClone#sync! never runs,
# so the Git History tab quietly reports `available: false` forever. From
# the outside this looks identical to "nothing has happened yet" — there is
# no error anywhere. This job makes the gap itself visible via a log line as
# soon as it happens, mirroring WorkerHostHealthTelemetryCheckJob's approach
# to a structurally similar silent-degrade risk.
class PollingQueueCoverageCheckJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  POLLING_QUEUE = "polling"

  def perform
    processes = live_worker_processes
    return if processes.nil? # can't tell right now (SQ tables unreachable); try again next tick
    return if processes.any? { |process| consumes_polling?(process) }

    Rails.logger.error(
      "[PollingQueueCoverageCheckJob] no live worker process in the fleet consumes the " \
      "`#{POLLING_QUEUE}` queue — GitHub issue/PR/merge polling is silently dead, and " \
      "GitHistory::RelayServer will never start anywhere either. Check SOLID_QUEUE_CONFIG " \
      "and every worker tier's config/queue*.yml."
    )
  end

  private

  def live_worker_processes
    SolidQueue::Process.where(kind: "Worker").to_a
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.debug("[PollingQueueCoverageCheckJob] SQ tables unreachable (#{e.class}); skipping coverage check")
    nil
  end

  # Delegates to WorkerQueueTopology's wildcard-aware matching (`"*"` /
  # `"foo*"` / exact) instead of a plain literal-inclusion check — a worker
  # whose registered queues are `"*"` (Solid Queue's own fallback when
  # SOLID_QUEUE_CONFIG points at a missing file, or a deliberately
  # unpartitioned single-worker deployment) does consume `polling`, and a
  # naive `split(",").include?("polling")` would misreport it as not
  # covered, producing a spurious "polling is dead" alarm.
  def consumes_polling?(process)
    WorkerQueueTopology.queues_include?(process.metadata["queues"].to_s.split(","), POLLING_QUEUE)
  end
end
