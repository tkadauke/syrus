# Decides whether this worker starts a queued Run now.
#
# Measured, not predicted. A worker takes more work while it is demonstrably
# healthy and backs off when it demonstrably is not:
#
#   * live memory pressure (PSI) over its ceiling defers everything guarded;
#   * measured free memory -- the pod limit minus a working set that excludes
#     reclaimable cache and slab -- below a fixed floor defers everything
#     guarded;
#   * compute work (everything but provider-bound agent turns) is bounded by
#     HostConcurrencyTarget, which grows while the worker is full and healthy
#     and halves when it is pressured.
#
# This replaced an allocator that charged every Run a predicted cost -- compute
# units, learned and fallback memory reservations, a reserve held back for agent
# turns, one whole-host grader per worker, an admission stagger. Each piece was
# sized for the worst case, and together they kept workers at a fraction of
# their CPU and memory refusing work while landing graders queued for hours.
# Overload is now bounded by the controller's halving and by the cgroup limits
# on spawned processes, and made cheap by the infrastructure retry of a Run a
# worker loses -- rather than prevented by refusing work up front.
class RunHostAdmission
  Decision = Data.define(:action, :reason, :delay, :details) do
    def admit? = action == "admit"
    def defer? = action == "defer"
  end

  HOST_SAMPLE_WINDOW = WorkflowAdmissionBudget::HOST_SAMPLE_WINDOW
  LIVENESS_WINDOW = 10.minutes
  RETRY_DELAY = 30.seconds
  # Free memory below this refuses new guarded work: enough for one more
  # process to start without pushing the pod into reclaim it cannot win.
  MEMORY_HEADROOM_FLOOR = 2.gigabytes
  # avg10 share of time at least one task stalled on memory. A few percent is
  # ordinary reclaim; sustained double digits means the host is thrashing.
  MEMORY_PRESSURE_CEILING = 10.0
  VISUAL_DIFF_STEP_KIND = "visual_diff"
  LIGHTWEIGHT_STEP_KINDS = %w[mergeability_preflight].freeze
  IO_BOUND_DIMENSIONS = %i[io_pressure].freeze
  CPU_DIMENSIONS = %i[cpu cpu_pressure].freeze
  BACKGROUND_TRIGGER_KINDS = %w[main_grader main_branch_repair agent_insight].freeze
  BUSY_REASON = "host_resource_semaphore_busy".freeze

  def self.call(...) = new(...).call

  def initialize(run:, queue_name: nil, now: Time.current)
    @run = run
    @queue_name = queue_name.to_s.presence
    @now = now
  end

  def call
    return admit("not_queued") unless run&.queued?
    return admit("non_compute_queue") unless compute_queue?
    return admit("missing_execution_graph") unless workflow && step
    return admit("control_plane_step") if control_plane_step?
    return defer("local_worker_pressure_critical") if critical_local_pressure?
    return admit("admission_control_disabled") unless AdmissionControl.enabled?
    return defer("landing_work_has_priority") if background_work_should_yield?
    return admit("resource_guard_not_needed") if step.kind.in?(LIGHTWEIGHT_STEP_KINDS)
    return busy("memory_pressure") if memory_pressure_exceeded?
    return busy("memory_headroom") if memory_headroom_low?
    return busy("grader_cpu_booked") if grader_cpu_booked?
    return admit("provider_bound_step") if provider_bound_candidate?
    return busy("concurrency_target") if active_compute_run_count >= concurrency_target

    book_whole_host_grader!
    admit("host_capacity_available")
  end

  private

  attr_reader :run, :queue_name, :now

  # A whole-host grader goes where the cores are free. The busy refusal is
  # reroutable, so DistributedRunAdmissionRouter hands it to the least-loaded
  # healthy worker instead of stacking it on a host whose CPUs are taken.
  def grader_cpu_booked?
    whole_host_grader_grant&.cpu_booked? || false
  end

  # Shards of one fan-out are claimed within seconds of each other, minutes
  # before any of them spawns a process, so the spawned-process view alone
  # shows every one of them an empty host. Booking the admitted grader in the
  # grant's in-flight registry closes that window; its real grant replaces the
  # entry when it spawns, and the registry drops it once the Run is terminal.
  def book_whole_host_grader!
    grant = whole_host_grader_grant
    GraderResourceGrant.record_inflight!(run.id, grant.whole_host_floor) if grant
  end

  def whole_host_grader_grant
    return @whole_host_grader_grant if defined?(@whole_host_grader_grant)

    @whole_host_grader_grant =
      if step.kind == "grader"
        grant = GraderResourceGrant.new(run: run, hostname: hostname)
        grant if GraderResourceRequest.from_details(step.details&.dig("resources"))&.unbounded_cpu?
      end
  end

  def admit(reason)
    Syrus::Metrics.counter(:syrus_admission_decisions_total).increment(tags: { decision: "admit", reason: reason })
    Decision.new(action: "admit", reason: reason, delay: nil, details: basic_details(reason))
  end

  def defer(reason, binding_term: nil)
    Syrus::Metrics.counter(:syrus_admission_decisions_total).increment(tags: { decision: "defer", reason: reason })
    Decision.new(action: "defer", reason: reason, delay: RETRY_DELAY, details: details(reason, binding_term))
  end

  def busy(binding_term) = defer(BUSY_REASON, binding_term: binding_term)

  def details(reason, binding_term)
    basic_details(reason).merge(
      "resource_guard_binding_terms" => [ binding_term ].compact,
      "active_compute_run_count" => active_compute_run_count,
      "concurrency_target" => concurrency_target,
      "host_cpu_count" => host_cpu_count,
      "host_memory_limit_bytes" => host_memory_limit_bytes,
      "current_memory_bytes" => current_memory_bytes,
      "memory_headroom_bytes" => memory_headroom_bytes,
      "memory_headroom_floor_bytes" => MEMORY_HEADROOM_FLOOR,
      "active_run_liveness_evidence" => active_run_liveness_evidence,
      "active_run_ids" => active_run_liveness_evidence.map { |evidence| evidence["run_id"] }
    ).compact
  end

  def basic_details(reason)
    {
      "reason" => reason,
      "hostname" => hostname,
      "worker_storage_key" => local_sample&.worker_storage_key,
      "sample_observed_at" => local_sample&.observed_at&.iso8601,
      "sample_health" => local_health,
      "step_kind" => step&.kind,
      "workflow_id" => workflow&.id,
      "run_id" => run&.id,
      "queue_name" => queue_name,
      "sticky_resume_queue" => queue_name.to_s.start_with?("resume-"),
      "memory_pressure_some" => memory_pressure_some,
      "memory_pressure_ceiling" => memory_pressure_ceiling
    }.compact
  end

  def control_plane_step?
    step.placement_policy == Step::PlacementPolicy::CONTROL_PLANE
  end

  def compute_queue?
    Workflow::TriggerKind.template_for(run.trigger_kind).queue_name.in?(%i[runs merges])
  rescue ArgumentError
    false
  end

  # IO pressure is produced by the disk-bound work on a host. An agent turn
  # spends nearly all of its wall time waiting on a provider API, so IO
  # pressure alone does not defer it; memory, disk space and CPU still defer
  # everything, because their overshoot kills a process instead of slowing it.
  def critical_local_pressure?
    return false unless local_health["level"] == "critical"
    return true unless provider_bound_candidate?

    (critical_health_dimensions - IO_BOUND_DIMENSIONS).any?
  end

  def critical_health_dimensions
    @critical_health_dimensions ||= local_sample ? WorkerHealthSampleAnalysis.critical_dimensions_for(local_sample) : []
  end

  # Agent turns are provider-bound and their real cost shows up in the
  # measurements, so they are not charged against the compute target.
  # visual_diff drives a browser and a preview app of its own, so it is.
  def provider_bound_candidate?
    step.agentic? && step.kind != VISUAL_DIFF_STEP_KIND
  end

  def background_work_should_yield?
    run.trigger_kind.to_s.in?(BACKGROUND_TRIGGER_KINDS) && local_health_warning? && active_landing_work_for_repository?
  end

  def active_landing_work_for_repository?
    Workflow
      .joins(:job)
      .where(jobs: { repository_id: workflow.job.repository_id })
      .where(state: Workflow::TriggerKind::ACTIVE_STATES)
      .where(trigger_kind: WorkDefinitions.landing_workflow_kinds)
      .where.not(id: workflow.id)
      .exists?
  end

  def local_health_warning?
    WorkerHealthSampleAnalysis::LEVEL_ORDER.fetch(local_health.fetch("level"), 0) >=
      WorkerHealthSampleAnalysis::LEVEL_ORDER.fetch("warning")
  end

  def local_health
    @local_health ||= (local_sample ? WorkerHealthSampleAnalysis.health_for(local_sample) : { level: "unknown", reasons: [] }).stringify_keys
  end

  def local_sample
    @local_sample ||= WorkerHostHealthSample
      .where(hostname: hostname)
      .where("observed_at >= ?", now - HOST_SAMPLE_WINDOW)
      .order(observed_at: :desc)
      .first
  end

  def memory_pressure_exceeded?
    memory_pressure_some.present? && memory_pressure_some >= memory_pressure_ceiling
  end

  def memory_pressure_some
    @memory_pressure_some ||= memory_pressure_snapshot["memory_pressure_some"]
  end

  def memory_pressure_snapshot
    @memory_pressure_snapshot ||= (WorkerHostHealthSampler.memory_pressure_snapshot || {}).stringify_keys
  rescue StandardError
    {}
  end

  def memory_pressure_ceiling
    Float(ENV.fetch("SYRUS_MEMORY_PRESSURE_CEILING", MEMORY_PRESSURE_CEILING))
  rescue ArgumentError, TypeError
    MEMORY_PRESSURE_CEILING
  end

  def memory_headroom_low?
    memory_headroom_bytes.present? && memory_headroom_bytes < MEMORY_HEADROOM_FLOOR
  end

  def memory_headroom_bytes
    return unless host_memory_limit_bytes && current_memory_bytes

    host_memory_limit_bytes - current_memory_bytes
  end

  def host_memory_limit_bytes
    @host_memory_limit_bytes ||= RunProcessParallelism.effective_memory_limit_bytes
  end

  def current_memory_bytes
    @current_memory_bytes ||= RunProcessParallelism.current_memory_bytes
  end

  def host_cpu_count
    @host_cpu_count ||= RunProcessParallelism.cpu_detection.count
  end

  # Pressure that should shrink the target: memory stalling at half the
  # deferral ceiling, or the memory dimension at warning or worse. CPU is
  # deliberately not here: a worker running graders shows CPU pressure because
  # it is busy, and halving on it collapsed a freshly restarted worker's target
  # from 8 to 1 within minutes while it had 13 GB free and no memory stall.
  def pressured?
    return true if memory_pressure_some.present? && memory_pressure_some >= memory_pressure_ceiling / 2
    return false unless local_sample

    WorkerHealthSampleAnalysis.dimensions_at_least(local_sample, "warning").include?(:memory)
  end

  # CPU at its target utilization (the health analysis warns at 90% used):
  # stop growing, but keep what is running. CPU contention slows work down;
  # it does not kill it.
  def saturated?
    return false unless local_sample

    (WorkerHealthSampleAnalysis.dimensions_at_least(local_sample, "warning") & CPU_DIMENSIONS).any?
  end

  def concurrency_target
    @concurrency_target ||= HostConcurrencyTarget.new(cpus: host_cpu_count, now: now)
      .observe!(active: active_compute_run_count, pressured: pressured?, saturated: saturated?)
  end

  def active_compute_run_count
    @active_compute_run_count ||= active_run_scope
      .where.not(steps: { kind: Step::AGENTIC_KINDS - [ VISUAL_DIFF_STEP_KIND ] })
      .where.not(steps: { kind: LIGHTWEIGHT_STEP_KINDS })
      .count
  end

  # A Run occupies this host when a process it spawned is still running here,
  # or -- for steps that work in the workflow's shared workspace -- when this
  # is that workspace's home host and the Run shows credible current ownership
  # (a fresh heartbeat, a recent start, or a recently touched runtime session).
  # A distributed grader runs from an immutable checkout on whichever worker
  # claimed it, so the workflow's home host says nothing about where it runs.
  def active_run_scope
    cutoff = LIVENESS_WINDOW.ago
    Run
      .where(state: "running")
      .where.not(id: run.id)
      .joins(step: :workflow)
      .left_outer_joins(:spawned_processes)
      .where(
        [
          "(spawned_processes.hostname = :hostname AND spawned_processes.finished_at IS NULL)",
          "(workflows.worker_hostname = :hostname AND steps.placement_policy <> :distributed_placement " \
            "AND (#{fresh_heartbeat_sql} OR #{live_runtime_session_sql}))"
        ].join(" OR "),
        hostname: hostname, cutoff: cutoff, distributed_placement: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT
      )
      .distinct
  end

  def fresh_heartbeat_sql
    "runs.last_heartbeat_at >= :cutoff OR (runs.last_heartbeat_at IS NULL AND runs.started_at >= :cutoff)"
  end

  def live_runtime_session_sql
    "EXISTS (SELECT 1 FROM runtime_sessions rs WHERE rs.run_id = runs.id " \
      "AND rs.state NOT IN ('failed', 'stopped') AND rs.updated_at >= :cutoff)"
  end

  # Auditable evidence for every Run currently counted against this host.
  def active_run_liveness_evidence
    @active_run_liveness_evidence ||= begin
      cutoff = LIVENESS_WINDOW.ago
      runs = active_run_scope.preload(:step, :spawned_processes).to_a
      session_run_ids = RuntimeSession.active.where(run_id: runs.map(&:id)).where("updated_at >= ?", cutoff).distinct.pluck(:run_id)
      runs.map do |active_run|
        heartbeat = active_run.last_heartbeat_at
        {
          "run_id" => active_run.id,
          "step_kind" => active_run.step&.kind,
          "unfinished_spawned_process" => active_run.spawned_processes.any? { |sp| sp.hostname == hostname && sp.finished_at.nil? },
          "fresh_heartbeat" => heartbeat.present? && heartbeat >= cutoff,
          "last_heartbeat_at" => heartbeat&.iso8601,
          "started_at" => active_run.started_at&.iso8601,
          "active_runtime_session" => session_run_ids.include?(active_run.id)
        }
      end.sort_by { |evidence| evidence["run_id"] }
    end
  end

  def hostname
    @hostname ||= SyrusVersion.hostname
  end

  def workflow
    @workflow ||= run.workflow
  end

  def step
    @step ||= run.step
  end
end
