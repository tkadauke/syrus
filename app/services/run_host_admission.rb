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
  ALWAYS_GUARDED_STEP_KINDS = (Step::AGENTIC_KINDS + HEAVY_STEP_KINDS).uniq.freeze

  def self.call(...) = new(...).call

  def initialize(run:, queue_name: nil, now: Time.current)
    @run = run
    @queue_name = queue_name.to_s.presence
    @now = now
  end

  def call
    return admit("not_queued") unless run&.queued?
    return admit("non_compute_queue") unless guarded_queue?
    return admit("missing_execution_graph") unless workflow && step
    return admit("resource_guard_not_needed") unless resource_guarded?(run)
    return defer("host_resource_semaphore_busy") if active_guarded_run_count >= GUARDED_RUNS_PER_HOST
    return defer("failed_worker_host_still_critical") if failed_worker_host_still_critical?
    return defer("local_worker_pressure_critical") if critical_local_pressure? && !sticky_resume_queue?

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
    payload = {
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
    payload["failed_worker_retry"] = failed_worker_retry_details if failed_worker_retry_details.present?
    payload
  end

  def sticky_resume_queue?
    queue_name.to_s.start_with?("resume-")
  end

  def guarded_queue?
    sticky_resume_queue? || workflow_template_class.queue_name.in?(%i[runs merges])
  end

  def critical_local_pressure?
    local_health.fetch(:level, local_health["level"]) == "critical"
  end

  def failed_worker_host_still_critical?
    return false unless critical_local_pressure?
    return false unless failed_worker_retry_details.present?

    failed_worker_retry_details.fetch("failed_hostname") == hostname
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

  def failed_worker_retry_details
    @failed_worker_retry_details ||= auto_retry_failed_worker_details || prior_run_failed_worker_details || {}
  end

  def auto_retry_failed_worker_details
    attempt = auto_retry_attempt
    return unless attempt&.failed_under_critical_pressure_on?(hostname)

    {
      "source" => "auto_retry_attempt",
      "auto_retry_attempt_id" => attempt.id,
      "source_run_id" => attempt.run_id,
      "failed_hostname" => attempt.failed_hostname,
      "failed_host_pressure_level" => attempt.failed_host_pressure_level,
      "failed_host_pressure_started_at" => attempt.failed_host_pressure_started_at&.iso8601,
      "failed_host_pressure_finished_at" => attempt.failed_host_pressure_finished_at&.iso8601,
      "failed_host_pressure_sample_count" => attempt.failed_host_pressure_sample_count,
      "failed_host_pressure_reasons" => attempt.failed_host_pressure_reasons || []
    }.compact
  end

  def auto_retry_attempt
    @auto_retry_attempt ||= begin
      artifact_id = workflow&.artifact("auto_retry_attempt_id")
      AutoRetryAttempt.find_by(id: artifact_id, job: run.job) ||
        AutoRetryAttempt
          .where(workflow: workflow, failure_classification: worker_died_classifications)
          .where(failed_hostname: hostname)
          .order(scheduled_at: :desc, id: :desc)
          .first
    end
  end

  def prior_run_failed_worker_details
    failed_run = step.runs
      .where.not(id: run.id)
      .where(state: "failed")
      .joins(:run_failure_classification)
      .where(run_failure_classifications: { classification: worker_died_classifications })
      .joins(:run_resource_summary)
      .where(run_resource_summaries: { hostname: hostname, host_pressure_level: "critical" })
      .order(finished_at: :desc, id: :desc)
      .first
    summary = failed_run&.run_resource_summary
    return unless failed_run && summary

    {
      "source" => "prior_step_run",
      "source_run_id" => failed_run.id,
      "failed_hostname" => summary.hostname,
      "failed_host_pressure_level" => summary.host_pressure_level,
      "failed_host_pressure_started_at" => summary.started_at&.iso8601,
      "failed_host_pressure_finished_at" => summary.finished_at&.iso8601,
      "failed_host_pressure_sample_count" => summary.host_sample_count,
      "failed_host_pressure_reasons" => summary.host_pressure_reasons || []
    }.compact
  end

  def worker_died_classifications
    @worker_died_classifications ||= [
      AutoRetryAttempt::WORKER_DIED_CLASSIFICATION,
      "worker_died_under_resource_pressure"
    ].freeze
  end

  def active_guarded_run_count
    @active_guarded_run_count ||= begin
      if active_always_guarded_run_scope.exists?
        1
      else
        active_run_scope
          .where.not(steps: { kind: ALWAYS_GUARDED_STEP_KINDS })
          .includes(:job, step: :workflow)
          .to_a
          .count { |candidate| resource_guarded?(candidate) }
      end
    end
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

  def workflow_template_class
    Workflows.for(trigger_kind: workflow&.trigger_kind || run.trigger_kind)
  end
end
