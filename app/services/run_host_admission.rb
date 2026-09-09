class RunHostAdmission
  Decision = Data.define(:action, :reason, :delay, :details) do
    def admit? = action == "admit"
    def defer? = action == "defer"
  end

  HOST_SAMPLE_WINDOW = WorkflowAdmissionBudget::HOST_SAMPLE_WINDOW
  RETRY_DELAY = 30.seconds

  # First distributed rollout: one active workflow Step per worker storage
  # slot. This is placement/admission, not capacity prediction. It deliberately
  # stays conservative so multiple Solid Queue threads in one worker process
  # cannot run two workflow steps against the same local workspace storage at
  # once.
  GUARDED_RUNS_PER_SLOT = 1

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
    return admit("admission_control_disabled") unless AppSetting.workflow_admission_control_enabled?

    # Measured first, and for every kind of run: a host in trouble should stop
    # taking work, not just stop taking *agentic* work. This is the gate that
    # replaced the predicted-cost budget, so it has to be the one that
    # actually decides.
    return defer("local_worker_pressure_critical") if critical_local_pressure?

    WorkflowStepWorkerSlot.release_inactive_holders!
    return admit("worker_step_slot_already_acquired") if active_slot_for_run?
    return defer("worker_step_slot_busy") unless acquire_slot

    admit("worker_step_slot_available")
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
      "active_slot_run_count" => active_slot_run_count,
      "guarded_runs_per_slot" => GUARDED_RUNS_PER_SLOT
    )
  end

  def basic_details(reason)
    {
      "reason" => reason,
      "hostname" => hostname,
      "worker_storage_key" => storage_key,
      "slot_key" => slot_key,
      "slot_key_source" => slot_key_source,
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

  def active_slot_run_count
    @active_slot_run_count ||= active_slot_scope.count
  end

  def active_slot_scope
    WorkflowStepWorkerSlot.active.where(slot_key: slot_key)
  end

  def active_slot_for_run?
    WorkflowStepWorkerSlot.active.where(run_id: run.id, slot_key: slot_key).exists?
  end

  def acquire_slot
    WorkflowStepWorkerSlot.acquire!(run: run, hostname: hostname, storage_key: storage_key)
  rescue WorkflowStepWorkerSlot::Conflict
    false
  end

  def hostname
    @hostname ||= SyrusVersion.hostname
  end

  def storage_key
    @storage_key ||= WorkerStorageIdentity.queue_key
  end

  def slot_key
    @slot_key ||= storage_key.presence || hostname
  end

  def slot_key_source
    storage_key.present? ? "worker_storage_key" : "hostname"
  end

  def workflow
    @workflow ||= run.workflow
  end

  def step
    @step ||= run.step
  end
end
