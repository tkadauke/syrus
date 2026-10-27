class DistributedRunAdmissionRouter
  REROUTABLE_REASONS = %w[local_worker_pressure_critical host_resource_semaphore_busy].freeze
  MAX_BACKOFF = 2.minutes

  Decision = Data.define(:action, :queue_name, :delay, :details) do
    def reroute? = action == "reroute"
  end

  def self.call(...) = new(...).call

  def initialize(run:, admission:, now: Time.current)
    @run = run
    @admission = admission
    @now = now
  end

  def call
    return backoff unless reroutable?

    candidates = eligible_workers
    prior_exclusions = current_exclusions
    rejected_hostname = admission.details["hostname"].presence || SyrusVersion.hostname
    exclusions = (prior_exclusions + [ rejected_hostname ]).compact.uniq
    # Least-loaded, not first-fit. `find` returned whichever eligible host the
    # live-worker list happened to name first, so every refusal in a burst
    # chose the same one.
    alternative = candidates
      .reject { |candidate| exclusions.include?(candidate.fetch("hostname")) }
      .select { |candidate| healthy_with_headroom?(candidate) }
      .min_by { |candidate| [ committed_load(candidate.fetch("hostname")), candidate.fetch("hostname") ] }

    considered = candidates.map { |candidate| candidate_diagnostics(candidate, exclusions:) }
    if alternative
      return Decision.new(
        action: "reroute",
        queue_name: WorkerStorageIdentity.dispatch_queue_name(hostname: alternative.fetch("hostname")),
        delay: nil,
        details: {
          "routing_decision" => "healthy_alternative",
          "rejecting_worker" => rejected_hostname,
          "rejecting_reason" => admission.reason,
          "excluded_workers" => exclusions,
          "healthy_alternatives_considered" => considered,
          "routed_worker" => alternative.fetch("hostname"),
          "routed_worker_storage_key" => alternative.fetch("worker_storage_key")
        }
      )
    end

    # Every compatible worker has either rejected this Run in the current
    # routing cycle or lacks healthy headroom. Clear the exclusions after a
    # bounded delay so recovery is retried without bouncing continuously.
    Decision.new(
      action: "defer",
      queue_name: nil,
      delay: backoff_delay,
      details: {
        "routing_decision" => "all_eligible_workers_pressured",
        "rejecting_worker" => rejected_hostname,
        "rejecting_reason" => admission.reason,
        "excluded_workers" => [],
        "completed_exclusion_cycle" => exclusions,
        "healthy_alternatives_considered" => considered
      }
    )
  end

  private

  attr_reader :run, :admission, :now

  def reroutable?
    run.distributed_parallel_run? && admission.reason.in?(REROUTABLE_REASONS)
  end

  def backoff
    Decision.new(action: "defer", queue_name: nil, delay: admission.delay, details: {})
  end

  def eligible_workers
    workers = Array(RunQueueResolver.resolve(run: run).details["live_workers"])
    workers.select do |worker|
      dispatch_queue = WorkerStorageIdentity.dispatch_queue_name(hostname: worker["hostname"])
      worker["eligible"] && Array(worker["queues"]).include?(dispatch_queue)
    end
  end

  def current_exclusions
    artifact = Workflow.find_by(id: run.workflow_id)&.artifact("run_host_admission").to_h
    return [] unless artifact["run_id"].to_i == run.id

    Array(artifact["excluded_workers"]).map(&:to_s)
  end

  def latest_sample(hostname)
    @latest_samples ||= WorkerHostHealthSample
      .worker_role
      .where("observed_at >= ?", now - RunHostAdmission::HOST_SAMPLE_WINDOW)
      .order(observed_at: :desc, id: :desc)
      .to_a
      .group_by(&:hostname)
      .transform_values(&:first)
    @latest_samples[hostname]
  end

  def healthy_with_headroom?(candidate)
    sample = latest_sample(candidate.fetch("hostname"))
    return false unless sample
    return false unless WorkerHealthSampleAnalysis.health_for(sample).fetch(:level).to_s == "ok"

    committed_load(candidate.fetch("hostname")) < RunProcessParallelism.host_capacity
  end

  # Everything already committed to a host: what is running on it, plus what
  # is waiting on its dispatch queue.
  #
  # The running count alone is what let a burst stack up. Each refusal was
  # routed independently, and each one saw a target with one run active and
  # five threads' worth of room -- so the same host was chosen again and
  # again. 53 Runs ended up queued behind one host's three threads while
  # three other hosts sat idle, and a Run on a `worker-<hostname>` queue can
  # only ever be claimed by that host. Counting the queue closes the loop:
  # once a host holds capacity's worth of work, it stops looking empty.
  def committed_load(hostname)
    @committed_load ||= {}
    @committed_load[hostname] ||= active_compute_runs(hostname) + pending_dispatch_depth(hostname)
  end

  # Depth of a host's dispatch queue: work routed to it that no thread has
  # picked up yet. Claimed executions are deliberately excluded -- those are
  # already counted by active_compute_runs.
  def pending_dispatch_depth(hostname)
    queue = WorkerStorageIdentity.dispatch_queue_name(hostname: hostname)
    SolidQueue::ReadyExecution.where(queue_name: queue).count +
      SolidQueue::ScheduledExecution.where(queue_name: queue).count
  rescue ActiveRecord::ActiveRecordError, NameError
    # The queue lives on its own connection and its tables are not loaded in
    # the test environment (single-database). A queue we cannot read must not
    # fail admission: fall back to the running-only view.
    0
  end

  def active_compute_runs(hostname)
    Run.where(state: "running")
      .joins(step: :workflow)
      .left_outer_joins(:spawned_processes)
      .where(
        "workflows.worker_hostname = :hostname OR " \
          "(spawned_processes.hostname = :hostname AND spawned_processes.finished_at IS NULL)",
        hostname: hostname
      )
      .distinct
      .count
  end

  def candidate_diagnostics(candidate, exclusions:)
    hostname = candidate.fetch("hostname")
    sample = latest_sample(hostname)
    health = sample ? WorkerHealthSampleAnalysis.health_for(sample).stringify_keys : { "level" => "unknown", "reasons" => [] }
    {
      "hostname" => hostname,
      "worker_storage_key" => candidate["worker_storage_key"],
      "health" => health,
      "active_compute_runs" => active_compute_runs(hostname),
      "pending_dispatch_depth" => pending_dispatch_depth(hostname),
      "committed_load" => committed_load(hostname),
      "host_compute_capacity" => RunProcessParallelism.host_capacity,
      "excluded" => exclusions.include?(hostname),
      "healthy_headroom" => !exclusions.include?(hostname) && healthy_with_headroom?(candidate)
    }
  end

  def backoff_delay
    prior = Workflow.find_by(id: run.workflow_id)&.artifact("run_host_admission").to_h
    count = prior["run_id"].to_i == run.id ? prior["deferral_count"].to_i : 0
    [ admission.delay * (2**[ count, 2 ].min), MAX_BACKOFF ].min
  end
end
