class RunHostAdmission
  Decision = Data.define(:action, :reason, :delay, :details) do
    def admit? = action == "admit"
    def defer? = action == "defer"
  end

  HOST_SAMPLE_WINDOW = WorkflowAdmissionBudget::HOST_SAMPLE_WINDOW
  RETRY_DELAY = 30.seconds

  # A backstop for measurement lag, not a capacity model. Host readings trail
  # by a sample interval, so a burst can be admitted against a stale "idle"
  # reading; this bounds how far that can overshoot before the next sample
  # lands. Sized to the `runs` thread pool -- the plumbing already allows this
  # many, and 24h of production peaked at 2-4 agents per host.
  #
  # It was 1, which made this a strict per-host mutex and was the single
  # binding constraint on throughput: a 52-second GitHub API call using 2.7%
  # CPU held the only slot on its pod, deferring landing 73 times in 36
  # minutes while every host sat below 45% CPU.
  GUARDED_RUNS_PER_HOST = 3

  # The other half of the lag defence: after admitting, leave a gap so the next
  # decision on this host sees a sample that reflects it. Cheaper and more
  # honest than predicting what the admitted work will cost.
  STAGGER_INTERVAL = 20.seconds

  # Agentic steps are the expensive ones by nature and are guarded on sight.
  #
  # Everything else is judged by the host's *current* state rather than by a
  # prediction of what the step will cost. Predicting was worse than useless
  # here: `WorkflowStepResourceProfile` records the host's ambient CPU and
  # memory while a step ran, not the step's own demand, so `prepare` (0.3%
  # process CPU) profiled at 93.5 cpu_pressure and `grader_collect` (3
  # seconds) at 88.2. Guarding on those numbers throttled cheap work hardest
  # and got worse the busier the fleet was -- the readings rise with load, so
  # the throttle tightened exactly when it should have relaxed.
  ALWAYS_GUARDED_STEP_KINDS = Step::AGENTIC_KINDS.freeze

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

    # Measured first, and for every kind of run: a host in trouble should stop
    # taking work, not just stop taking *agentic* work. This is the gate that
    # replaced the predicted-cost budget, so it has to be the one that
    # actually decides.
    return defer("local_worker_pressure_critical") if critical_local_pressure?

    # Beyond that, only agentic runs are rationed per host, and only to bound
    # how far a burst can overshoot a stale sample.
    return admit("resource_guard_not_needed") unless resource_guarded?(run)
    return defer("host_resource_semaphore_busy") if active_guarded_run_count >= GUARDED_RUNS_PER_HOST
    return defer("host_admission_staggering") if admitted_within_stagger_window?

    admit("host_capacity_available")
  end

  private

  attr_reader :run, :queue_name, :now

  def admit(reason)
    Decision.new(action: "admit", reason: reason, delay: nil, details: basic_details(reason))
  end

  def defer(reason)
    Decision.new(action: "defer", reason: reason, delay: RETRY_DELAY, details: details(reason))
  end

  def details(reason)
    basic_details(reason).merge(
      "active_guarded_run_count" => active_guarded_run_count,
      "guarded_runs_per_host" => GUARDED_RUNS_PER_HOST
    )
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

  # Host readings trail the work that produced them, so admitting several runs
  # against one sample overshoots before the next sample can object. Leaving a
  # gap between admissions on a host means each decision sees a measurement
  # that already reflects the previous one.
  #
  # Keyed on the most recently *started* guarded run rather than a separate
  # ledger: the runs themselves are the record, so there is no new state to
  # keep consistent, and a worker restart cannot lose it.
  def admitted_within_stagger_window?
    last_started = active_always_guarded_run_scope.maximum(:started_at)
    return false if last_started.blank?

    last_started > now - STAGGER_INTERVAL
  end

  def critical_local_pressure?
    local_health.fetch(:level, local_health["level"]) == "critical"
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
    candidate_step = candidate.step
    return false unless candidate_step

    candidate_step.agentic?
  end

  def active_always_guarded_run_scope
    active_run_scope.where(steps: { kind: ALWAYS_GUARDED_STEP_KINDS })
  end

  def active_run_scope
    Run
      .where(state: "running")
      .where.not(id: run.id)
      .joins(step: :workflow)
      .where(workflows: { worker_hostname: hostname })
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
