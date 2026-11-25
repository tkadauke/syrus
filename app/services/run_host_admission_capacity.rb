require "etc"
require_relative "run_process_parallelism"

# What a worker publishes about its size, for fleet-wide decisions made on
# another host (GraderFanoutAdmission, routing, metrics). Measurements only:
# the unit arithmetic and agent reserves that used to live here were part of
# the predicted-cost allocator RunHostAdmission no longer uses.
module RunHostAdmissionCapacity
  # Ready graders the fleet materializes per CPU. Host admission is what
  # actually starts them, so this only has to keep enough work queued that no
  # worker idles while it waits for the next fanout wave.
  FANOUT_RUNS_PER_CPU = 2

  module_function

  def host_compute_capacity
    RunProcessParallelism.cpu_detection.count
  end

  def snapshot
    detection = RunProcessParallelism.cpu_detection
    {
      "effective_cpu_count" => detection.count,
      "cpu_source" => detection.source,
      "cpu_fallback_in_effect" => detection.source == "undetectable_fallback",
      "host_compute_capacity" => detection.count,
      "memory_limit_bytes" => RunProcessParallelism.effective_memory_limit_bytes
    }.compact
  end
end
