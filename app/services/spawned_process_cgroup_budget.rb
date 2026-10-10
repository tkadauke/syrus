class SpawnedProcessCgroupBudget
  VERSION = 1
  DEFAULT_MEMORY_HIGH_FRACTION = 0.9
  DEFAULT_LIMIT_FRACTION = 0.75
  DEFAULT_RAILS_RESERVED_BYTES = 1.gigabyte
  DEFAULT_FILESYSTEM_RESERVED_FRACTION = 0.1
  DEFAULT_FILESYSTEM_RESERVED_BYTES = 512.megabytes

  Result = Data.define(:memory_max_bytes, :memory_high_bytes, :memory_swap_max_bytes, :details)

  def self.for(...) = new(...).call

  def initialize(spawned_process:)
    @spawned_process = spawned_process
  end

  def call
    memory_max = configured_bytes("SYRUS_SPAWN_MEMORY_MAX_BYTES") || adaptive_memory_max_bytes
    return Result.new(memory_max_bytes: nil, memory_high_bytes: nil, memory_swap_max_bytes: nil, details: details(nil)) unless memory_max&.positive?

    memory_high = configured_bytes("SYRUS_SPAWN_MEMORY_HIGH_BYTES") ||
      (memory_max * DEFAULT_MEMORY_HIGH_FRACTION).floor
    swap_max = configured_bytes("SYRUS_SPAWN_MEMORY_SWAP_MAX_BYTES", allow_zero: true)
    swap_max = SpawnedProcessCgroup::DEFAULT_SWAP_MAX_BYTES if swap_max.nil?

    Result.new(
      memory_max_bytes: memory_max,
      memory_high_bytes: memory_high,
      memory_swap_max_bytes: swap_max,
      details: details(memory_max)
    )
  end

  private

  attr_reader :spawned_process

  def adaptive_memory_max_bytes
    return unless effective_memory_limit_bytes&.positive?

    [ fair_share_memory_bytes, fractional_ceiling_bytes ].compact.min
  end

  def fair_share_memory_bytes
    return unless reservable_memory_bytes&.positive?

    [ (reservable_memory_bytes.to_f / concurrent_slots * admission_units).floor, 1 ].max
  end

  def fractional_ceiling_bytes
    return unless effective_memory_limit_bytes&.positive?

    (effective_memory_limit_bytes * DEFAULT_LIMIT_FRACTION).floor
  end

  def reservable_memory_bytes
    return unless effective_memory_limit_bytes&.positive?

    [ effective_memory_limit_bytes - rails_reserved_bytes - filesystem_reserved_bytes, 0 ].max
  end

  def details(memory_max)
    {
      "version" => VERSION,
      "source" => configured_bytes("SYRUS_SPAWN_MEMORY_MAX_BYTES") ? "env_override" : "adaptive",
      "run_type" => policy.name,
      "admission_units" => admission_units,
      "concurrent_slots" => concurrent_slots,
      "host_compute_capacity" => host_compute_capacity,
      "effective_memory_limit_bytes" => effective_memory_limit_bytes,
      "rails_reserved_bytes" => rails_reserved_bytes,
      "filesystem_reserved_bytes" => filesystem_reserved_bytes,
      "reservable_memory_bytes" => reservable_memory_bytes,
      "memory_max_bytes" => memory_max
    }.compact
  end

  def policy
    @policy ||= SpawnedProcessCgroupBudget::Policy.for(spawned_process)
  end

  def admission_units
    policy.admission_units.clamp(1, host_compute_capacity)
  end

  def concurrent_slots
    [
      configured_job_concurrency,
      active_same_host_slots,
      1
    ].max
  end

  def configured_job_concurrency
    Integer(ENV.fetch("JOB_CONCURRENCY", 3), 10).clamp(1, host_compute_capacity)
  rescue ArgumentError
    3.clamp(1, host_compute_capacity)
  end

  def active_same_host_slots
    SpawnedProcess
      .where(hostname: spawned_process.hostname, finished_at: nil)
      .where.not(id: spawned_process.id)
      .count + 1
  end

  def host_compute_capacity
    @host_compute_capacity ||= RunProcessParallelism.host_capacity
  end

  def effective_memory_limit_bytes
    @effective_memory_limit_bytes ||= RunProcessParallelism.effective_memory_limit_bytes
  end

  def rails_reserved_bytes
    configured_bytes("SYRUS_SPAWN_RAILS_RESERVED_BYTES") ||
      [ (effective_memory_limit_bytes.to_i * 0.15).floor, DEFAULT_RAILS_RESERVED_BYTES ].max
  end

  # Page cache can be charged to whichever cgroup first faults a page in, so a
  # worker-side checkout copy before spawn is still pod-level filesystem
  # overhead. This reserve is not a replacement for the checkout fan-out fix.
  def filesystem_reserved_bytes
    configured_bytes("SYRUS_SPAWN_FILESYSTEM_RESERVED_BYTES") ||
      [ (effective_memory_limit_bytes.to_i * DEFAULT_FILESYSTEM_RESERVED_FRACTION).floor, DEFAULT_FILESYSTEM_RESERVED_BYTES ].max
  end

  def configured_bytes(name, allow_zero: false)
    raw = ENV[name].to_s.strip
    return nil if raw.blank?
    value = Integer(raw, 10)
    return nil if value.negative?
    return nil if value.zero? && !allow_zero

    value
  rescue ArgumentError
    nil
  end

  class Policy
    def self.for(spawned_process)
      policies.find { |policy| policy.matches?(spawned_process) }.new(spawned_process)
    end

    def self.policies
      [ Agentic, Grader, Default ]
    end

    def initialize(spawned_process)
      @spawned_process = spawned_process
    end

    def self.matches?(_spawned_process) = false

    def admission_units = configured_units("SYRUS_SPAWN_DEFAULT_CAPACITY_UNITS", 1)

    def name = self.class.name.demodulize.underscore

    private

    attr_reader :spawned_process

    def configured_units(name, fallback)
      Integer(ENV.fetch(name, fallback), 10)
    rescue ArgumentError
      fallback
    end
  end

  class Agentic < Policy
    def self.matches?(spawned_process)
      step = spawned_process.run&.step
      step&.agentic? || spawned_process.kind == "agent"
    end

    def admission_units = configured_units("SYRUS_AGENTIC_CAPACITY_UNITS", 2)
  end

  class Grader < Policy
    def self.matches?(spawned_process)
      step = spawned_process.run&.step
      step&.kind&.in?(%w[grader preflight_grader]) || spawned_process.kind == "grader"
    end

    def admission_units = configured_units("SYRUS_GRADER_CAPACITY_UNITS", 1)
  end

  class Default < Policy
    def self.matches?(_spawned_process) = true
  end
end
