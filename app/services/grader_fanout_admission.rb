class GraderFanoutAdmission
  Decision = Data.define(:steps, :available_slots, :capacity, :active_runs, :reason) do
    def deferred? = steps.empty?
  end

  RECHECK_DELAY = RunHostAdmission::RETRY_DELAY

  def self.call(...) = new(...).call

  def initialize(workflow:, steps:, now: Time.current)
    @workflow = workflow
    @steps = steps.sort_by { |step| [ step.position, step.id ] }
    @now = now
  end

  def call
    capacity = healthy_worker_capacity
    active_runs = active_grader_runs
    available_slots = [ capacity - active_runs, 0 ].max
    reason = available_slots.positive? ? "capacity_available" : "grader_capacity_saturated"

    Decision.new(
      steps: steps.first(available_slots),
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

  def live_worker_capacities
    SolidQueue::Process.where.not(last_heartbeat_at: nil).filter_map do |process|
      next if process.last_heartbeat_at < InstanceVersion::HEARTBEAT_STALE_THRESHOLD.ago

      diagnostics = process.metadata.to_h["capability_diagnostics"].to_h["admission_capacity"].to_h
      capacity = diagnostics["host_compute_capacity"].to_i
      next unless capacity.positive?

      {
        hostname: process.metadata.to_h["hostname"].presence || process.hostname,
        capacity: capacity,
        grader_units: [ diagnostics["grader_capacity_units"].to_i, 1 ].max,
        reserved_units: diagnostics["agentic_reserved_units"].to_i.clamp(0, capacity - 1)
      }
    end.uniq { |worker| worker.fetch(:hostname) }
  rescue ActiveRecord::ActiveRecordError, NameError
    []
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
end
