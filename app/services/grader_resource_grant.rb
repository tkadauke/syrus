# Resolves a GraderResourceRequest into the cores and memory a grader actually
# gets on this host. The sole allocator: the number a grader sizes itself with
# and the ceiling it runs under must come from here, not from two independent
# calculations over the same host.
#
# Replaces RunProcessParallelism's per-run divisor, which paid the worst case
# unconditionally -- `host_capacity / max(concurrent, JOB_CONCURRENCY=3)` gave
# a single rspec grader on a 10-CPU worker 2 cores whether or not any other
# grader existed. Here concurrent claims are *summed from what they asked for*
# rather than counted as presumed slots, so an undeclared (assumed serial)
# grader costs one core and a `cpu: all` grader takes the rest.
#
# See docs/plans/grader-resource-grants.md.
class GraderResourceGrant
  # Matches SpawnedProcessCgroupBudget::DEFAULT_LIMIT_FRACTION: a declaration
  # may not claim more of the pod than the adaptive budget would ever hand out.
  MEMORY_LIMIT_FRACTION = 0.75

  Result = Data.define(:cpu_cores, :memory_max_bytes, :details) do
    def to_h
      { "cpu_cores" => cpu_cores, "memory_max_bytes" => memory_max_bytes, "details" => details }.compact
    end
  end

  def self.for(...) = new(...).call

  # Process-local record of grants handed out but not yet visible as a
  # SpawnedProcess row. Several grader Runs can be claimed by one threaded
  # Solid Queue worker before any of them spawns; without this they would each
  # see an idle host and each claim all of it. Cross-pod concurrency needs no
  # registry -- those claims are already SpawnedProcess rows.
  @inflight = {}
  @inflight_mutex = Mutex.new

  class << self
    def record_inflight!(run_id, cores)
      return unless run_id

      @inflight_mutex.synchronize { @inflight[run_id] = cores }
    end

    def release_inflight!(run_id)
      @inflight_mutex.synchronize { @inflight.delete(run_id) }
    end

    def reset_inflight!
      @inflight_mutex.synchronize { @inflight.clear }
    end

    # Self-pruning: an entry whose Run has reached a terminal state is dropped,
    # so a crashed or killed grader cannot hold a claim forever and no explicit
    # release is required for correctness. Queued counts as live -- a Run can
    # still be queued when its grader builds its environment, and pruning it
    # there would reopen the very race the registry exists to close.
    def inflight_claims(excluding_run_id:)
      snapshot = @inflight_mutex.synchronize { @inflight.dup }
      snapshot.delete(excluding_run_id)
      return {} if snapshot.empty?

      live = Run.where(id: snapshot.keys).where.not(state: Run::TERMINAL_STATES).pluck(:id).to_set
      stale = snapshot.keys - live.to_a
      @inflight_mutex.synchronize { stale.each { |id| @inflight.delete(id) } } if stale.any?
      snapshot.slice(*live.to_a)
    rescue StandardError => e
      Rails.logger.warn("[GraderResourceGrant] inflight prune failed: #{e.class}: #{e.message}")
      snapshot.to_h
    end
  end

  def initialize(run:, request: nil, hostname: SyrusVersion.hostname)
    @run = run
    @request = request || GraderResourceRequest.from_details(run&.step&.details&.dig("resources")) || GraderResourceRequest.new
    @hostname = hostname
  end

  def call
    cores = resolve_cpu_cores
    self.class.record_inflight!(run&.id, cores)

    Result.new(
      cpu_cores: cores,
      memory_max_bytes: resolve_memory_bytes,
      details: {
        "host_capacity" => host_capacity,
        "requested_cpu" => request.cpu,
        "requested_cpu_min" => request.cpu_min,
        "requested_memory_bytes" => request.memory_bytes,
        "granted_cpu_cores" => cores,
        "fixed_claims" => fixed_claim_cores,
        "unbounded_claimants" => unbounded_claimant_count,
        "below_cpu_min" => cores < request.cpu_min
      }.compact
    )
  end

  private

  attr_reader :run, :request, :hostname

  def resolve_cpu_cores
    remainder = [ host_capacity - fixed_claim_cores, 1 ].max

    cores =
      if request.unbounded_cpu?
        # Every unbounded claimant gets an equal share of what the bounded
        # claims leave behind, so two concurrent `cpu: all` graders split the
        # remainder instead of both taking it.
        [ remainder / (unbounded_claimant_count + 1), 1 ].max
      else
        # Leave one core per unbounded claimant rather than starving it.
        [ [ request.cpu, remainder - unbounded_claimant_count ].min, 1 ].max
      end

    cores.clamp(1, host_capacity)
  end

  def resolve_memory_bytes
    return nil unless request.memory_bytes&.positive?

    ceiling = memory_ceiling_bytes
    return request.memory_bytes unless ceiling&.positive?

    [ request.memory_bytes, ceiling ].min
  end

  def memory_ceiling_bytes
    limit = RunProcessParallelism.effective_memory_limit_bytes
    return nil unless limit&.positive?

    (limit * MEMORY_LIMIT_FRACTION).floor
  end

  def host_capacity
    @host_capacity ||= RunProcessParallelism.host_capacity
  end

  def fixed_claim_cores
    concurrent_claims.sum { |claim| claim.unbounded_cpu? ? 0 : claim.cpu_ceiling(host_capacity) } +
      inflight_cores
  end

  def unbounded_claimant_count
    concurrent_claims.count(&:unbounded_cpu?)
  end

  # Inflight grants are already resolved core counts, so they count as fixed
  # claims of exactly the size they were handed. A run that has since spawned
  # is dropped here: it is already counted through concurrent_claims, and
  # charging it on both sides would shrink every later grant for no reason.
  def inflight_cores
    @inflight_cores ||= self.class
      .inflight_claims(excluding_run_id: run&.id)
      .except(*spawned_run_ids)
      .values
      .sum
  end

  def concurrent_claims
    concurrent_spawns.map { |process| claim_for(process) }
  end

  def spawned_run_ids
    concurrent_spawns.filter_map(&:run_id)
  end

  def concurrent_spawns
    @concurrent_spawns ||= begin
      scope = SpawnedProcess
        .where(hostname: hostname, finished_at: nil, kind: "grader")
        .includes(run: :step)
      scope = scope.where.not(run_id: run.id) if run&.id
      scope.to_a
    rescue StandardError => e
      Rails.logger.warn("[GraderResourceGrant] concurrent claim lookup failed: #{e.class}: #{e.message}")
      []
    end
  end

  def claim_for(process)
    details = process.run&.step&.details
    GraderResourceRequest.from_details(details&.dig("resources")) || GraderResourceRequest.new
  end
end
