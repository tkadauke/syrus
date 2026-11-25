module Execution
  # `pids_max` is a per-spawn process-tree ceiling written to the cgroup's
  # `pids.max`; unlike RLIMIT_NPROC it counts descendants of this one spawn
  # regardless of the user, and applies to root as well.
  ResourceLimits = Data.define(
    :memory_max,
    :cpu_max,
    :io_weight,
    :pids_max
  ) do
    def initialize(memory_max:, cpu_max:, io_weight:, pids_max: nil)
      super
    end
  end
end
