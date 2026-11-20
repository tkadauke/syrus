class GraderFanoutAdmission
  Decision = Data.define(:steps, :available_slots, :capacity, :active_runs, :reason) do
    def deferred? = steps.empty?
  end

  RECHECK_DELAY = RunHostAdmission::RETRY_DELAY

  def self.call(...) = new(...).call

  # Capacity is instance-wide, so observing headroom and materializing the
  # Runs that consume it must share an instance-wide database lock. A Ruby
  # mutex would still let two worker pods admit the same slots.
  def self.synchronize(workflow:, steps:, now: Time.current, &block)
    AppSetting.current.with_lock do
      block.call(new(workflow: workflow, steps: steps, now: now).call)
    end
  end

  def initialize(workflow:, steps:, now: Time.current)
    @workflow = workflow
    @steps = steps.sort_by { |step| [ step.position, step.id ] }
    @now = now
  end

  def call
    capacity = healthy_worker_capacity
    active_runs = active_grader_runs
    available_slots = [ capacity - active_runs, 0 ].max
    fair_turn = fair_turn?
    grantable = fair_turn ? available_slots : spare_slots_beyond_older_demand(available_slots)
    released_steps = steps.first(grantable)
    reason = if !fair_turn && released_steps.empty?
      "waiting_for_fair_turn"
    elsif available_slots.positive?
      "capacity_available"
    else
      "grader_capacity_saturated"
    end

    Decision.new(
      steps: released_steps,
      available_slots: available_slots,
      capacity: capacity,
      active_runs: active_runs,
      reason: reason
    )
  end

  private

  attr_reader :workflow, :steps, :now

  # Workers publish the exact capacity inputs used by RunHostAdmission. Keep
  # one agentic unit in reserve, matching its grader semaphore, so admitting a
  # large grader set cannot consume the host slot needed to repair that set.
  def healthy_worker_capacity
    workers = live_worker_capacities
    return local_fallback_capacity if workers.empty?

    workers.sum do |worker|
      next 0 if critically_pressured?(worker.fetch(:hostname))

      capacity = worker.fetch(:capacity)
      grader_units = worker.fetch(:grader_units)
      reserved_units = worker.fetch(:reserved_units)
      [ (capacity - reserved_units) / grader_units, 1 ].max
    end
  end

  # SolidQueue writes its own process metadata, which never carries Syrus's
  # capability diagnostics; workers publish those on their InstanceVersion and
  # health samples. Reading only the process metadata found no worker at all
  # in production, so every decision fell back to the deciding pod's own
  # capacity -- one to four grader slots for the whole fleet. Resolve the
  # diagnostics the way RunQueueResolver does.
  def live_worker_capacities
    SolidQueue::Process.where.not(last_heartbeat_at: nil).filter_map do |process|
      next if process.last_heartbeat_at < InstanceVersion::HEARTBEAT_STALE_THRESHOLD.ago

      hostname = process.metadata.to_h["hostname"].presence || process.hostname
      diagnostics = capability_diagnostics_for(process, hostname).to_h["admission_capacity"].to_h
      capacity = diagnostics["host_compute_capacity"].to_i
      next unless capacity.positive?

      {
        hostname: hostname,
        capacity: capacity,
        grader_units: [ diagnostics["grader_capacity_units"].to_i, 1 ].max,
        reserved_units: diagnostics["agentic_reserved_units"].to_i.clamp(0, capacity - 1)
      }
    end.uniq { |worker| worker.fetch(:hostname) }
  rescue ActiveRecord::ActiveRecordError, NameError
    []
  end

  def capability_diagnostics_for(process, hostname)
    process.metadata.to_h["capability_diagnostics"].presence ||
      worker_instances_by_hostname[hostname]&.capability_diagnostics.presence ||
      latest_health_samples[hostname]&.capability_diagnostics.presence ||
      {}
  end

  def worker_instances_by_hostname
    @worker_instances_by_hostname ||= InstanceVersion.fresh.where(role: "worker").index_by(&:hostname)
  end

  def local_fallback_capacity
    capacity = RunHostAdmissionCapacity.host_compute_capacity
    grader_units = RunHostAdmissionCapacity.grader_capacity_units(capacity)
    reserved_units = RunHostAdmissionCapacity.agentic_reserved_units(capacity)
    [ (capacity - reserved_units) / grader_units, 1 ].max
  end

  def critically_pressured?(hostname)
    sample = latest_health_samples[hostname]
    sample && WorkerHealthSampleAnalysis.health_for(sample).fetch(:level) == "critical"
  end

  def latest_health_samples
    @latest_health_samples ||= WorkerHostHealthSample.worker_role
      .where("observed_at >= ?", WorkflowAdmissionBudget::HOST_SAMPLE_WINDOW.ago(now))
      .order(observed_at: :desc, id: :desc)
      .to_a
      .index_by(&:hostname)
  end

  # Queued Runs already represent runnable work committed to the worker pool;
  # counting only running processes would recreate the dispatch burst.
  def active_grader_runs
    Run.active.joins(:step).where(steps: { kind: %w[grader preflight_grader] }).count
  end

  # A workflow that receives a partial wave moves to the back of this queue.
  # Only workflows that still have an unmaterialized queued grader participate,
  # so a stale artifact cannot hold the turn after its fanout has completed.
  def fair_turn?
    own_deferred_at = deferred_at_for(workflow) || now
    oldest = deferred_workflows.min_by do |candidate|
      [ deferred_at_for(candidate), candidate.id ]
    end
    oldest.nil? || ([ own_deferred_at, workflow.id ] <=> [ deferred_at_for(oldest), oldest.id ]) <= 0
  end

  # Fairness orders contended capacity; it must not idle spare capacity. Older
  # deferred workflows keep first claim on as many slots as they still have
  # unmaterialized graders, and only the remainder goes to a later workflow.
  # Holding every slot for the oldest workflow let one that could not start
  # (an unadmitted grader that never got its recheck) starve every grader
  # behind it -- a landing train sat behind a main-branch grader with the
  # whole fleet idle.
  def spare_slots_beyond_older_demand(available_slots)
    own_deferred_at = deferred_at_for(workflow) || now
    older_ids = deferred_workflows.select do |candidate|
      ([ deferred_at_for(candidate), candidate.id ] <=> [ own_deferred_at, workflow.id ]).negative?
    end.map(&:id)
    older_demand = unmaterialized_graders.where(workflow_id: older_ids).count
    [ available_slots - older_demand, 0 ].max
  end

  def unmaterialized_graders
    Step
      .where(
        kind: %w[grader preflight_grader],
        placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
        state: "queued"
      )
      .where.missing(:runs)
  end

  def deferred_workflows
    @deferred_workflows ||= load_deferred_workflows
  end

  def load_deferred_workflows
    workflow_ids = unmaterialized_graders
      .where.not(workflow_id: workflow.id)
      .distinct
      .pluck(:workflow_id)

    Workflow
      .where(id: workflow_ids, state: Workflow::TriggerKind::ACTIVE_STATES)
      .includes(:workflow_artifact_values)
      .select { |candidate| deferred_at_for(candidate).present? }
  end

  def deferred_at_for(candidate)
    value = candidate.artifact("grader_fanout_admission").to_h["deferred_at"]
    Time.iso8601(value) if value.present?
  rescue ArgumentError
    nil
  end
end
