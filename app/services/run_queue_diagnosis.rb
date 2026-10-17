class RunQueueDiagnosis
  def self.call(run) = new(run).call

  def initialize(run)
    @run = run
  end

  def call
    return unless run.queued?
    return diagnosis("start_blocked", start_blocked_details) if start_blocked_reason.present?
    return diagnosis("host_admission_deferred", host_admission_details) if host_admission_details

    queue_job = matching_queue_job
    return diagnosis("no_run_job") unless queue_job

    return diagnosis("concurrency_blocked", queue_name: queue_job.queue_name) if execution_exists?(SolidQueue::BlockedExecution, queue_job)

    if (scheduled = execution_for(SolidQueue::ScheduledExecution, queue_job))
      scheduled_details = { queue_name: queue_job.queue_name, scheduled_at: scheduled.scheduled_at&.iso8601 }
      return diagnosis("scheduled", scheduled_details) if scheduled.scheduled_at&.future?

      return diagnosis("unknown", scheduled_details)
    end

    return diagnosis("claimed_not_started", queue_name: queue_job.queue_name) if execution_exists?(SolidQueue::ClaimedExecution, queue_job)

    diagnose_ready(queue_job)
  rescue NameError, ActiveRecord::StatementInvalid
    diagnosis("unknown")
  end

  private

  attr_reader :run

  def start_blocked_reason
    run.workflow&.artifact("start_blocked_reason")
  end

  def start_blocked_details
    {
      reason: start_blocked_reason,
      details: run.workflow&.artifact("start_blocked_details") || run.workflow&.artifact("run_queue_blocked")
    }.compact
  end

  def host_admission_details
    artifact = run.workflow&.artifact("run_host_admission").to_h
    return if artifact["run_id"].to_i != run.id
    return unless artifact["action"] == "defer"

    artifact.slice(
      "reason", "deferral_count", "first_deferred_at", "deferred_at", "retry_at",
      "resource_guard_binding_terms", "active_compute_units", "candidate_compute_units",
      "host_compute_capacity", "current_memory_bytes", "active_reserved_memory_bytes",
      "candidate_reserved_memory_bytes", "host_memory_budget_bytes",
      "host_memory_effective_budget_bytes", "grader_memory_reserve_bytes"
    ).symbolize_keys
  end

  def matching_queue_job
    scope = SolidQueue::Job.where(class_name: "RunJob", finished_at: nil).order(created_at: :desc)
    Array(SolidQueueRunJobQuery.matching(scope: scope, run_id: run.id, limit: 100)).first
  end

  def execution_exists?(model, queue_job)
    model.where(job_id: queue_job.id).exists?
  end

  def execution_for(model, queue_job)
    model.where(job_id: queue_job.id).first
  end

  def diagnose_ready(queue_job)
    return diagnosis("unknown", queue_name: queue_job.queue_name) unless execution_exists?(SolidQueue::ReadyExecution, queue_job)

    resolver_details = RunQueueResolver.resolve(run: run).details
    workers = Array(resolver_details["live_workers"])
    details = {
      queue_name: queue_job.queue_name,
      requirements: resolver_details["requirements"],
      live_worker_count: workers.count { |worker| worker["selected_queue"] },
      live_worker_queues: workers.flat_map { |worker| Array(worker["queues"]) }.uniq.sort
    }
    return diagnosis("no_live_workers", details) if workers.empty?
    return diagnosis("ready_no_consumer", details) unless InstanceVersion.worker_queue_live?(queue_job.queue_name)
    return diagnosis("ready_waiting_for_slot", details) if consuming_workers_busy?(queue_job.queue_name)

    diagnosis("unknown", details)
  end

  def consuming_workers_busy?(queue_name)
    workers = SolidQueue::Process.where.not(last_heartbeat_at: nil).select do |process|
      process.last_heartbeat_at >= InstanceVersion::HEARTBEAT_STALE_THRESHOLD.ago &&
        InstanceVersion.queue_names(process.metadata&.dig("queues")).include?(queue_name.to_s)
    end
    return false if workers.empty?

    capacities = workers.index_with { |worker| Integer(worker.metadata&.dig("thread_pool_size"), exception: false) }
    return false if capacities.values.any? { |capacity| capacity.nil? || !capacity.positive? }

    claimed = SolidQueue::ClaimedExecution.where(process_id: workers.map(&:id)).group(:process_id).count
    workers.all? { |worker| claimed.fetch(worker.id, 0) >= capacities.fetch(worker) }
  end

  def diagnosis(kind, details = {})
    { kind: kind, details: details.compact }
  end
end
