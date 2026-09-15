class SolidQueueCleanupJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  BATCH_SIZE = 100
  MAX_BATCHES = 10
  SLEEP_BETWEEN_BATCHES = 0.05
  STALE_READY_JOB_AGE = 7.days

  # Orphan sweep gets its own, larger budget: there were 553,671 of these in
  # production when it was written, and the ordinary 1,000-rows-per-run budget
  # would have taken two days to work through them.
  ORPHAN_BATCH_SIZE = 500
  ORPHAN_MAX_BATCHES = 20
  # An enqueue is not always a single transaction (`enqueue_after_transaction_commit`,
  # and bulk enqueues in particular), so a job row can legitimately exist for a
  # moment with no execution row yet. Only rows well past that window are
  # orphans rather than work in flight. Production's orphans were all at least
  # a month old, so this is a wide margin over what the evidence required.
  ORPHAN_MIN_AGE = 6.hours
  OBSOLETE_READY_QUEUE_NAMES = [ "default" ].freeze
  OBSOLETE_READY_QUEUE_PREFIXES = [ "resume-" ].freeze
  DUPLICATE_WORKFLOW_PHASE_ADMISSION_SCAN_LIMIT = 2_500
  DUPLICATE_POLLING_SCAN_LIMIT = 10_000

  def perform
    prune_finished_jobs
    prune_obsolete_ready_jobs
    prune_dead_resume_ready_executions
    prune_orphaned_jobs
    prune_duplicate_workflow_phase_admission_jobs
    prune_duplicate_polling_jobs
  end

  private

  # A job row with no execution row of any kind is reachable by nothing: no
  # worker will ever claim it, and `prune_finished_jobs` skips it because it
  # never finished. They are invisible dead weight in a table every dispatcher
  # scan reads -- production accumulated 553,671 of them, 83% of the table, all
  # from a single job class over two days in August.
  #
  # Walks by id cursor rather than re-filtering from the start each batch, so a
  # stretch of live rows cannot stall the sweep on them forever.
  def prune_orphaned_jobs
    cutoff = ORPHAN_MIN_AGE.ago
    last_id = 0
    pruned = 0

    ORPHAN_MAX_BATCHES.times do |index|
      candidate_ids = SolidQueue::Job
                        .where(finished_at: nil)
                        .where(created_at: ...cutoff)
                        .where("id > ?", last_id)
                        .order(:id)
                        .limit(ORPHAN_BATCH_SIZE)
                        .pluck(:id)
      break if candidate_ids.empty?

      last_id = candidate_ids.last
      orphan_ids = candidate_ids - execution_backed_job_ids(candidate_ids)
      next if orphan_ids.empty?

      SolidQueue::Job.where(id: orphan_ids).delete_all
      pruned += orphan_ids.size

      sleep(SLEEP_BETWEEN_BATCHES) unless index == ORPHAN_MAX_BATCHES - 1
    end

    Rails.logger.info("[SolidQueueCleanupJob] pruned #{pruned} orphaned job rows") if pruned.positive?
  end

  def execution_backed_job_ids(job_ids)
    [ SolidQueue::ReadyExecution, SolidQueue::ClaimedExecution, SolidQueue::FailedExecution,
      SolidQueue::ScheduledExecution, SolidQueue::BlockedExecution ]
      .flat_map { |model| model.where(job_id: job_ids).pluck(:job_id) }
      .uniq
  end

  # A Run that has already reached a terminal state can still own a ready
  # execution on a storage-affinity `resume-` queue whose worker is gone. The
  # queue names a worker's storage key; once that storage no longer exists,
  # nothing advertises the queue and nothing will ever claim the row.
  #
  # WorkEngine::Reconciler covers the *queued* Run case
  # (`queued_run_on_dead_resume_queue`, which re-enqueues onto a live queue),
  # and is deliberately left to it here. But the reconciler scans Runs, so a
  # terminal Run's leftover row is invisible to it and simply sits.
  #
  # The row is inert -- RunJob returns early on a terminal Run -- but it is not
  # harmless: while it sits there it pins `syrus_global_queue_oldest_age_seconds`,
  # the headline "is Syrus keeping up" number, at an age that grows forever. One
  # dead row had the dashboard reporting a 31-hour backlog that did not exist.
  def prune_dead_resume_ready_executions
    dead_queues = SolidQueue::ReadyExecution
                    .where("queue_name LIKE ?", "resume-%")
                    .distinct
                    .pluck(:queue_name)
                    .reject { |queue_name| InstanceVersion.worker_queue_live?(queue_name) }
    return if dead_queues.empty?

    job_ids = SolidQueue::ReadyExecution
                .where(queue_name: dead_queues)
                .limit(BATCH_SIZE * MAX_BATCHES)
                .pluck(:job_id)
    return if job_ids.empty?

    stranded = SolidQueue::Job.where(id: job_ids, class_name: "RunJob").select do |job|
      run_terminal?(job)
    end
    return if stranded.empty?

    stranded_ids = stranded.map(&:id)
    SolidQueue::ReadyExecution.where(job_id: stranded_ids).delete_all
    SolidQueue::Job.where(id: stranded_ids).delete_all

    Rails.logger.info(
      "[SolidQueueCleanupJob] pruned #{stranded_ids.size} ready executions stranded on dead resume queues"
    )
  end

  def run_terminal?(job)
    run_id = Array(active_job_arguments(job.arguments)).first
    return false if run_id.blank?

    Run.find_by(id: run_id)&.terminal? || false
  end

  def prune_finished_jobs
    finished_before = SolidQueue.clear_finished_jobs_after.ago
    MAX_BATCHES.times do |index|
      job_ids = SolidQueue::Job
                  .clearable(finished_before: finished_before)
                  .order(:finished_at, :id)
                  .limit(BATCH_SIZE)
                  .pluck(:id)
      break if job_ids.empty?

      SolidQueue::Job.where(id: job_ids).delete_all

      sleep(SLEEP_BETWEEN_BATCHES) unless index == MAX_BATCHES - 1
    end
  end

  def prune_obsolete_ready_jobs
    stale_ready_cutoff = STALE_READY_JOB_AGE.ago

    MAX_BATCHES.times do |index|
      job_ids = obsolete_ready_job_scope(stale_ready_cutoff).limit(BATCH_SIZE).pluck(:id)
      break if job_ids.empty?

      SolidQueue::ReadyExecution.where(job_id: job_ids).delete_all
      SolidQueue::Job.where(id: job_ids).delete_all

      sleep(SLEEP_BETWEEN_BATCHES) unless index == MAX_BATCHES - 1
    end
  end

  def obsolete_ready_job_scope(stale_ready_cutoff)
    ready_table = SolidQueue::ReadyExecution.quoted_table_name
    queue_predicates = OBSOLETE_READY_QUEUE_NAMES.map do |queue_name|
      ActiveRecord::Base.sanitize_sql_array([ "#{ready_table}.queue_name = ?", queue_name ])
    end
    queue_predicates += OBSOLETE_READY_QUEUE_PREFIXES.map do |prefix|
      ActiveRecord::Base.sanitize_sql_array([ "#{ready_table}.queue_name LIKE ?", "#{prefix}%" ])
    end

    SolidQueue::Job
      .joins(:ready_execution)
      .where("#{ready_table}.created_at < ?", stale_ready_cutoff)
      .where(queue_predicates.join(" OR "))
  end

  def prune_duplicate_workflow_phase_admission_jobs
    seen = {}
    duplicate_ids = []

    workflow_phase_admission_scope.find_each(batch_size: BATCH_SIZE) do |job|
      key = workflow_phase_admission_key(job.arguments)
      next if key.blank?

      if seen.key?(key)
        duplicate_ids << job.id
      else
        seen[key] = job.id
      end

      break if seen.size + duplicate_ids.size >= DUPLICATE_WORKFLOW_PHASE_ADMISSION_SCAN_LIMIT
    end

    return if duplicate_ids.empty?

    SolidQueue::ReadyExecution.where(job_id: duplicate_ids).delete_all
    SolidQueue::ScheduledExecution.where(job_id: duplicate_ids).delete_all
    SolidQueue::Job.where(id: duplicate_ids).delete_all

    Rails.logger.info("[SolidQueueCleanupJob] pruned #{duplicate_ids.size} duplicate WorkflowPhaseAdmissionJob rows")
  end

  def workflow_phase_admission_scope
    SolidQueue::Job
      .where(class_name: "WorkflowPhaseAdmissionJob", finished_at: nil)
      .where(queue_name: "control_plane")
      .where.not(id: SolidQueue::ClaimedExecution.select(:job_id))
      .where.not(id: SolidQueue::BlockedExecution.select(:job_id))
      .where.not(id: SolidQueue::FailedExecution.select(:job_id))
      .includes(:ready_execution, :scheduled_execution)
      .order(:created_at, :id)
  end

  def workflow_phase_admission_key(arguments)
    args = active_job_arguments(arguments)
    return nil unless args.is_a?(Array)

    workflow_id = args[0].presence
    return nil if workflow_id.blank?

    step_id = args[1].presence
    [ workflow_id.to_s, step_id.to_s.presence || "workflow" ]
  end

  def prune_duplicate_polling_jobs
    seen = {}
    duplicate_ids = []

    duplicate_polling_scope.find_each(batch_size: BATCH_SIZE) do |job|
      key = duplicate_polling_key(job)
      next if key.blank?

      if seen.key?(key)
        duplicate_ids << job.id
      else
        seen[key] = job.id
      end

      break if seen.size + duplicate_ids.size >= DUPLICATE_POLLING_SCAN_LIMIT
    end

    return if duplicate_ids.empty?

    SolidQueue::ReadyExecution.where(job_id: duplicate_ids).delete_all
    SolidQueue::ScheduledExecution.where(job_id: duplicate_ids).delete_all
    SolidQueue::Job.where(id: duplicate_ids).delete_all

    Rails.logger.info("[SolidQueueCleanupJob] pruned #{duplicate_ids.size} duplicate polling jobs")
  end

  def duplicate_polling_scope
    SolidQueue::Job
      .where(finished_at: nil)
      .where(queue_name: "polling")
      .where.not(id: SolidQueue::ClaimedExecution.select(:job_id))
      .where.not(id: SolidQueue::BlockedExecution.select(:job_id))
      .where.not(id: SolidQueue::FailedExecution.select(:job_id))
      .includes(:ready_execution, :scheduled_execution)
      .order(:class_name, :created_at, :id)
  end

  def duplicate_polling_key(job)
    args = active_job_arguments(job.arguments)
    return nil unless args.is_a?(Array)

    [ job.class_name, JSON.generate(args) ]
  rescue JSON::GeneratorError
    nil
  end

  def active_job_arguments(arguments)
    payload = arguments.is_a?(String) ? JSON.parse(arguments) : arguments
    payload.is_a?(Hash) ? (payload["arguments"] || payload[:arguments]) : payload
  rescue JSON::ParserError, TypeError
    nil
  end
end
