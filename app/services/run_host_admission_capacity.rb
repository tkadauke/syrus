# The per-host numbers RunHostAdmission rations work with, as a pure function
# of the CPU quota and a few env vars. These are what decide whether a queued
# Run starts, yet they exist only inside the worker process that computes them;
# workers publish this snapshot with their heartbeat (see
# WorkerCapabilities.current) so the admin API can show it.
# Self-contained (no ActiveSupport) because config/queue.yml reaches it through
# WorkerCapabilities before Rails is loaded.
require "etc"
require_relative "run_process_parallelism"

module RunHostAdmissionCapacity
  AGENTIC_CAPACITY_UNITS_ENV = "SYRUS_AGENTIC_CAPACITY_UNITS".freeze
  GRADER_CAPACITY_UNITS_ENV = "SYRUS_GRADER_CAPACITY_UNITS".freeze
  AGENTIC_RESERVED_UNITS_ENV = "SYRUS_AGENTIC_RESERVED_UNITS".freeze
  MEMORY_UTILIZATION = 0.8

  module_function

  def host_compute_capacity
    RunProcessParallelism.host_capacity
  end

  def agentic_capacity_units(capacity = host_compute_capacity)
    ENV.fetch(AGENTIC_CAPACITY_UNITS_ENV, 2).to_i.clamp(1, capacity)
  end

  def grader_capacity_units(capacity = host_compute_capacity)
    ENV.fetch(GRADER_CAPACITY_UNITS_ENV, 1).to_i.clamp(1, capacity)
  end

  def agentic_runs_per_host(capacity = host_compute_capacity)
    [ capacity / agentic_capacity_units(capacity), 1 ].max
  end

  def grader_runs_per_host(capacity = host_compute_capacity)
    [ capacity / grader_capacity_units(capacity), 1 ].max
  end

  def agentic_reserved_units(capacity = host_compute_capacity)
    configured = ENV[AGENTIC_RESERVED_UNITS_ENV]
    return configured.to_i.clamp(0, capacity - 1) unless configured.to_s.strip.empty?

    [ agentic_capacity_units(capacity), capacity - 1 ].min
  end

  def snapshot
    detection = RunProcessParallelism.cpu_detection
    capacity = [ (detection.count * RunProcessParallelism::CPU_UTILIZATION).floor, 1 ].max
    memory_limit = RunProcessParallelism.effective_memory_limit_bytes

    {
      "effective_cpu_count" => detection.count,
      "cpu_source" => detection.source,
      "cpu_fallback_in_effect" => detection.source == "undetectable_fallback",
      "host_compute_capacity" => capacity,
      "agentic_capacity_units" => agentic_capacity_units(capacity),
      "agentic_runs_per_host" => agentic_runs_per_host(capacity),
      "grader_capacity_units" => grader_capacity_units(capacity),
      "grader_runs_per_host" => grader_runs_per_host(capacity),
      "agentic_reserved_units" => agentic_reserved_units(capacity),
      "memory_limit_bytes" => memory_limit,
      "memory_budget_bytes" => memory_limit && (memory_limit * MEMORY_UTILIZATION).floor,
      "memory_reserve_bytes" => memory_limit && [ memory_limit / capacity, 1 ].max * agentic_reserved_units(capacity)
    }.compact
  end
end
