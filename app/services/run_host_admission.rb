class RunHostAdmission
  Decision = Data.define(:action, :reason, :delay, :details) do
    def admit? = action == "admit"
    def defer? = action == "defer"
  end

  HOST_SAMPLE_WINDOW = WorkflowAdmissionBudget::HOST_SAMPLE_WINDOW
  RETRY_DELAY = 30.seconds

  # Host readings trail by a sample interval, so admission also budgets active
  # work against the container's effective CPU quota. This scales from laptops
  # to large workers instead of imposing one fleet-wide concurrency constant.
  IO_INTENSIVE_GRADER_BYTES = 1.gigabyte

  # visual_diff previews drive a headless browser against a spawned preview
  # app -- IO-heavy on top of the agent turn itself. Colocating more than one
  # on a host that is already under warning-or-worse pressure is exactly the
  # kind of burst that pushed hosts into the critical IO pressure seen in the
  # 2026-09-14 batches, so this step kind gets a narrower cap than the general
  # agentic guard once the host stops looking idle.
  VISUAL_DIFF_STEP_KIND = "visual_diff"

  # Agentic starts are staggered so the next decision sees a sample reflecting
  # the previous one. Grader fanout is not staggered; its shared capacity budget
  # and inner process allocation provide the bound without serial startup.
  STAGGER_INTERVAL = 20.seconds

  # Agentic steps are the expensive ones by nature and are guarded on sight.
  # Grader runs are guarded on sight because fanout can make several siblings
  # ready against the same stale health sample. Command-attributed high-IO
  # graders use a narrower semaphore.
  #
  # Everything else is judged by the host's *current* state rather than by a
  # prediction of what the step will cost. We only trust command-attributed
  # profiles for the grader exception; host-correlated profiles still describe
  # ambient fleet pressure rather than the step's own demand.
  ALWAYS_GUARDED_STEP_KINDS = Step::AGENTIC_KINDS.freeze
  BACKGROUND_TRIGGER_KINDS = %w[main_grader main_branch_repair agent_insight].freeze

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

    # Measured before admitting any compute-bound run: a host in trouble should
    # stop taking more agentic or high-cost grader work. Control-plane steps
    # already returned above; they are the cheap orchestration path that can
    # unblock or terminate expensive work.
    return defer("local_worker_pressure_critical") if critical_local_pressure?
    return defer("landing_work_has_priority") if background_work_should_yield?

    # Beyond that, agentic and grader runs are rationed per host to bound how
    # far a burst can overshoot a stale sample.
    return admit("resource_guard_not_needed") unless resource_guarded?(run)
    return defer("host_resource_semaphore_busy") if resource_guard_full?
    return defer("host_admission_staggering") if admitted_within_stagger_window?

    admit("host_capacity_available")
  end

  private

  attr_reader :run, :queue_name, :now

  def admit(reason)
    Syrus::Metrics.counter(:syrus_admission_decisions_total).increment(tags: { decision: "admit" })
    Decision.new(action: "admit", reason: reason, delay: nil, details: basic_details(reason))
  end

  def defer(reason)
    Syrus::Metrics.counter(:syrus_admission_decisions_total).increment(tags: { decision: "defer" })
    Decision.new(action: "defer", reason: reason, delay: RETRY_DELAY, details: details(reason))
  end

  def details(reason)
    basic_details(reason).merge(
      "active_guarded_run_count" => active_guarded_run_count,
      "active_compute_units" => active_compute_units,
      "candidate_compute_units" => candidate_compute_units,
      "guarded_runs_per_host" => guarded_runs_per_host,
      "host_compute_capacity" => host_compute_capacity,
      "resource_guard_kind" => resource_guard_kind,
      "active_grader_run_count" => grader_guard? ? active_grader_run_count : nil,
      "active_io_intensive_grader_run_count" => io_intensive_grader_guard? ? active_io_intensive_grader_run_count : nil,
      "active_visual_diff_preview_run_count" => resource_guard_kind == "visual_diff_preview" ? active_visual_diff_preview_run_count : nil
    ).compact
  end

  def basic_details(reason)
    {
      "reason" => reason,
      "hostname" => hostname,
      "sample_observed_at" => local_sample&.observed_at&.iso8601,
      "sample_health" => local_health.stringify_keys,
      "step_kind" => step&.kind,
      "workflow_id" => workflow&.id,
      "run_id" => run&.id,
      "queue_name" => queue_name,
      "sticky_resume_queue" => sticky_resume_queue?
    }.compact
  end

  def sticky_resume_queue?
    queue_name.to_s.start_with?("resume-")
  end

  def control_plane_step?
    step.placement_policy == Step::PlacementPolicy::CONTROL_PLANE
  end

  # Host readings trail the work that produced them, so admitting several runs
  # against one sample overshoots before the next sample can object. Leaving a
  # gap between admissions on a host means each decision sees a measurement
  # that already reflects the previous one.
  #
  # Keyed on the most recently *started* guarded run rather than a separate
  # ledger: the runs themselves are the record, so there is no new state to
  # keep consistent, and a worker restart cannot lose it.
  def admitted_within_stagger_window?
    return false if grader_guard?

    last_started = active_always_guarded_run_scope.maximum(:started_at)
    return false if last_started.blank?

    last_started > now - STAGGER_INTERVAL
  end

  def critical_local_pressure?
    local_health.fetch(:level, local_health["level"]) == "critical"
  end

  def background_work_should_yield?
    background_work? && local_health_warning? && active_landing_work_for_repository?
  end

  def background_work?
    run.trigger_kind.to_s.in?(BACKGROUND_TRIGGER_KINDS)
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

  def compute_queue?
    Workflow::TriggerKind.template_for(run.trigger_kind).queue_name.in?(%i[runs merges])
  rescue ArgumentError
    false
  end

  def local_health
    @local_health ||= begin
      health = local_sample ? WorkerHealthSampleAnalysis.health_for(local_sample) : { level: "unknown", reasons: [] }
      health.stringify_keys
    end
  end

  def local_sample
    @local_sample ||= WorkerHostHealthSample
      .where(hostname: hostname)
      .where("observed_at >= ?", now - HOST_SAMPLE_WINDOW)
      .order(observed_at: :desc)
      .first
  end

  # A straight count now that guarding is "is it agentic", rather than loading
  # every candidate to ask a profile what it might cost.
  def active_guarded_run_count
    @active_guarded_run_count ||= active_always_guarded_run_scope.count
  end

  def resource_guarded?(candidate)
    resource_guard_kind(candidate).present?
  end

  def resource_guard_full?
    return true if active_compute_units + candidate_compute_units > host_compute_capacity
    return active_io_intensive_grader_run_count >= io_intensive_runs_per_host if io_intensive_grader_guard?
    return active_visual_diff_preview_run_count >= io_intensive_runs_per_host if resource_guard_kind == "visual_diff_preview"

    false
  end

  def guarded_runs_per_host
    case resource_guard_kind
    when "grader" then grader_runs_per_host
    when "io_intensive_grader", "visual_diff_preview" then io_intensive_runs_per_host
    else agentic_runs_per_host
    end
  end

  def host_compute_capacity
    @host_compute_capacity ||= RunProcessParallelism.host_capacity
  end

  # Agent turns have substantial memory and subprocess overhead even when the
  # provider call itself is mostly waiting on the network. Give them two units
  # of the same host budget a grader consumes.
  def agentic_runs_per_host
    [ host_compute_capacity / agentic_capacity_units, 1 ].max
  end

  def grader_runs_per_host
    [ host_compute_capacity / grader_capacity_units, 1 ].max
  end

  def agentic_capacity_units
    ENV.fetch("SYRUS_AGENTIC_CAPACITY_UNITS", 2).to_i.clamp(1, host_compute_capacity)
  end

  def grader_capacity_units
    ENV.fetch("SYRUS_GRADER_CAPACITY_UNITS", 1).to_i.clamp(1, host_compute_capacity)
  end

  def candidate_compute_units
    resource_guard_kind == "agentic" || resource_guard_kind == "visual_diff_preview" ? agentic_capacity_units : grader_capacity_units
  end

  def active_compute_units
    (active_guarded_run_count * agentic_capacity_units) + (active_grader_run_count * grader_capacity_units)
  end

  # Storage topology is not discoverable portably from inside every worker.
  # Operators can state it directly; the automatic default scales slowly with
  # compute capacity instead of imposing one fleet-wide constant.
  def io_intensive_runs_per_host
    configured = ENV["SYRUS_IO_INTENSIVE_RUNS_PER_HOST"].to_i
    return configured if configured.positive?

    [ (host_compute_capacity / 8.0).ceil, 1 ].max
  end

  def grader_guard?
    resource_guard_kind.in?(%w[grader io_intensive_grader])
  end

  def io_intensive_grader_guard?
    resource_guard_kind == "io_intensive_grader"
  end

  # visual_diff is itself agentic, so check it before the general agentic
  # budget and apply the narrower host-scaled IO budget when pressure warns.
  def resource_guard_kind(candidate = run)
    candidate_step = candidate.step
    return unless candidate_step
    return "visual_diff_preview" if visual_diff_preview_step?(candidate_step) && local_health_warning?
    return "agentic" if candidate_step.agentic?
    return unless grader_step?(candidate_step)
    return "io_intensive_grader" if io_intensive_command_profile?(candidate_step)

    "grader"
  end

  def visual_diff_preview_step?(candidate_step)
    candidate_step.kind == VISUAL_DIFF_STEP_KIND
  end

  def local_health_warning?
    WorkerHealthSampleAnalysis::LEVEL_ORDER.fetch(local_health.fetch("level"), 0) >=
      WorkerHealthSampleAnalysis::LEVEL_ORDER.fetch("warning")
  end

  def grader_step?(candidate_step)
    candidate_step.kind.in?(%w[grader preflight_grader])
  end

  def io_intensive_command_profile?(candidate_step)
    matching_profiles_for(candidate_step).any? do |profile|
      prediction = profile.conservative_prediction
      prediction.fetch(:prediction_source) == "command_attributed" &&
        prediction.fetch(:process_attributed_io_bytes).to_f >= IO_INTENSIVE_GRADER_BYTES
    end
  end

  def matching_profiles_for(candidate_step)
    profile_keys = resource_profile_keys_for(candidate_step)
    step_kinds = profile_keys.map(&:first).uniq
    WorkflowStepResourceProfile
      .where(
        repository: candidate_step.workflow.job.repository,
        agent_provider: candidate_step.workflow.agent_provider,
        trigger_kind: candidate_step.workflow.trigger_kind,
        job_kind: candidate_step.workflow.job.kind.to_s,
        step_kind: step_kinds
      )
      .to_a
      .select do |profile|
        profile_keys.any? do |step_kind, grader_name|
          profile.step_kind == step_kind && (grader_name.nil? || profile.grader_name.to_s == grader_name)
        end
      end
  end

  def resource_profile_keys_for(candidate_step)
    Step::Kind.fetch(candidate_step.kind).resource_profile_keys_for(candidate_step)
  rescue ArgumentError
    [ [ candidate_step.kind, "" ] ]
  end

  def active_grader_run_count
    @active_grader_run_count ||= active_run_scope.where(steps: { kind: %w[grader preflight_grader] }).count
  end

  def active_io_intensive_grader_run_count
    @active_io_intensive_grader_run_count ||= active_run_scope
      .where(steps: { kind: %w[grader preflight_grader] })
      .includes(step: { workflow: :job })
      .select { |active_run| io_intensive_command_profile?(active_run.step) }
      .size
  end

  def active_visual_diff_preview_run_count
    @active_visual_diff_preview_run_count ||= active_run_scope.where(steps: { kind: VISUAL_DIFF_STEP_KIND }).count
  end

  def active_always_guarded_run_scope
    active_run_scope.where(steps: { kind: ALWAYS_GUARDED_STEP_KINDS })
  end

  def active_run_scope
    Run
      .where(state: "running")
      .where.not(id: run.id)
      .joins(step: :workflow)
      .left_outer_joins(:spawned_processes)
      .where(
        [
          "workflows.worker_hostname = :hostname",
          "(spawned_processes.hostname = :hostname AND spawned_processes.finished_at IS NULL)"
        ].join(" OR "),
        hostname: hostname
      )
      .distinct
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
