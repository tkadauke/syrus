class RunHostAdmission
  Decision = Data.define(:action, :reason, :delay, :details) do
    def admit? = action == "admit"
    def defer? = action == "defer"
  end

  HOST_SAMPLE_WINDOW = WorkflowAdmissionBudget::HOST_SAMPLE_WINDOW
  RETRY_DELAY = 30.seconds
  GUARDED_RUNS_PER_HOST = 1
  HEAVY_STEP_KINDS = %w[grader preflight_grader].freeze
  CPU_HEAVY_PRESSURE = 50.0
  CPU_HEAVY_PROCESS_PERCENT = 75.0

  def self.call(...) = new(...).call

  def initialize(run:, now: Time.current)
    @run = run
    @now = now
  end

  def call
    return admit("not_queued") unless run&.queued?
    return admit("non_compute_queue") unless run.agent_queue?
    return admit("missing_execution_graph") unless workflow && step
    return defer("local_worker_pressure_critical") if critical_local_pressure?
    return admit("resource_guard_not_needed") unless resource_guarded?(run)
    return defer("host_resource_semaphore_busy") if active_guarded_run_count >= GUARDED_RUNS_PER_HOST

    admit("host_capacity_available")
  end

  private

  attr_reader :run, :now

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
      "run_id" => run&.id
    }.compact
  end

  def critical_local_pressure?
    local_health.fetch(:level, local_health["level"]) == "critical"
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

  def active_guarded_run_count
    @active_guarded_run_count ||= Run
      .where(state: "running")
      .where.not(id: run.id)
      .joins(step: :workflow)
      .where(workflows: { worker_hostname: hostname })
      .includes(:step, step: :workflow)
      .to_a
      .count { |candidate| resource_guarded?(candidate) }
  end

  def resource_guarded?(candidate)
    candidate_step = candidate.step
    return false unless candidate_step
    return true if candidate_step.agentic?
    return true if HEAVY_STEP_KINDS.include?(candidate_step.kind)

    prediction = prediction_for(candidate)
    prediction.fetch(:cpu_pressure).to_f >= CPU_HEAVY_PRESSURE ||
      prediction.fetch(:process_attributed_cpu_percent).to_f >= CPU_HEAVY_PROCESS_PERCENT ||
      prediction.fetch(:duration_seconds).to_f >= WorkflowAdmissionBudget::HIGH_COST_SECONDS
  end

  def prediction_for(candidate)
    candidate_step = candidate.step
    profile = profiles_for(candidate).first
    return profile.conservative_prediction if profile

    Step::Kind.fetch(candidate_step.kind).resource_profile_defaults ||
      WorkflowStepResourceProfile::CONSERVATIVE_DEFAULTS
  rescue ArgumentError
    WorkflowStepResourceProfile::CONSERVATIVE_DEFAULTS
  end

  def profiles_for(candidate)
    candidate_step = candidate.step
    profile_keys = Step::Kind.fetch(candidate_step.kind).resource_profile_keys_for(candidate_step)
    step_kinds = profile_keys.map(&:first).uniq
    base = WorkflowStepResourceProfile.where(
      repository: candidate.job.repository,
      agent_provider: candidate.workflow.agent_provider,
      trigger_kind: candidate.workflow.trigger_kind,
      job_kind: candidate.job.kind.to_s,
      step_kind: step_kinds
    )

    base.to_a.select do |profile|
      profile_keys.any? do |step_kind, grader_name|
        profile.step_kind == step_kind && (grader_name.nil? || profile.grader_name.to_s == grader_name)
      end
    end
  rescue ArgumentError
    []
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
