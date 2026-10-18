require "etc"

class RunProcessParallelism
  CPU_UTILIZATION = 0.8
  # What to assume this process may use when nothing tells us our actual
  # share. See undetectable_cpu_count for why this is deliberately small.
  UNDETECTABLE_CPU_COUNT = 4
  CPU_LIMIT_ENV = "SYRUS_WORKER_CPU_LIMIT".freeze

  def self.for(...) = new(...).call

  def self.host_capacity
    [ (effective_cpu_count * CPU_UTILIZATION).floor, 1 ].max
  end

  def self.effective_cpu_count
    cgroup_v2_cpu_count || cgroup_v1_cpu_count || undetectable_cpu_count
  end

  # `Etc.nprocessors` reports the machine's CPUs, not this process's share of
  # them, so trusting it inside a container without a CPU limit is how a
  # worker comes to believe it owns the node.
  #
  # That is not hypothetical. Production worker workloads declared
  # `requests.cpu` but no `limits.cpu`; Kubernetes only writes `cpu.max` into
  # the cgroup from *limits*, so the quota probes above found "max", fell
  # through to `Etc.nprocessors`, and every worker sized its parallelism as
  # though the whole node were its own. Two workers shared one node, each
  # believing that, and nodes sat at 99% CPU. Processes then starved, missed
  # their heartbeats, and were declared dead: 51 worker deaths in a day, 62%
  # of all grader failures, each orphaning a run, consuming a grader-loop
  # iteration and reporting as "no progress" until the merge train was torn
  # down. The landing queue could not drain.
  #
  # So an undetectable share is treated as a small one. Under-using a worker
  # is recoverable and visible; over-subscribing a node kills the work on it
  # and looks like a grader problem. Set #{CPU_LIMIT_ENV} to this process's
  # real core budget to get accurate sizing without waiting for a manifest
  # change, or give the pod a `limits.cpu` and the quota probes take over.
  def self.undetectable_cpu_count
    configured = positive_int(ENV[CPU_LIMIT_ENV])
    return configured if configured

    assumed = [ Etc.nprocessors, UNDETECTABLE_CPU_COUNT ].min
    warn_about_undetectable_cpu_share(assumed)
    assumed
  end

  def self.warn_about_undetectable_cpu_share(assumed)
    return if @warned_about_undetectable_cpu_share

    @warned_about_undetectable_cpu_share = true
    Rails.logger.warn(
      "[RunProcessParallelism] no CPU quota visible to this process " \
      "(cgroup cpu.max is unset); assuming #{assumed} core(s) of " \
      "#{Etc.nprocessors} on the host rather than trusting the host count. " \
      "Set #{CPU_LIMIT_ENV} to this process's real budget, or give the pod " \
      "a resources.limits.cpu, to size parallelism accurately."
    )
  end

  def self.reset_undetectable_cpu_warning!
    @warned_about_undetectable_cpu_share = false
  end

  def self.positive_int(raw)
    value = Integer(raw.to_s.strip, 10)
    value.positive? ? value : nil
  rescue ArgumentError, TypeError
    nil
  end

  def self.effective_memory_limit_bytes
    limits = [ cgroup_v2_memory_limit, cgroup_v1_memory_limit, proc_memory_total ].compact
    limits.min
  end

  def self.current_memory_bytes
    cgroup_v2_memory_working_set || cgroup_v1_memory_working_set
  end

  def self.cgroup_memory_current_bytes
    positive_bytes(File.read("/sys/fs/cgroup/memory.current").strip)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def self.cgroup_memory_events
    File.readlines("/sys/fs/cgroup/memory.events").each_with_object({}) do |line, events|
      key, value = line.split
      events[key] = Integer(value, 10) if key.present? && value.present?
    rescue ArgumentError
      next
    end
  rescue Errno::ENOENT, Errno::EACCES
    {}
  end

  def initialize(run:, hostname: SyrusVersion.hostname)
    @run = run
    @hostname = hostname
  end

  def call
    [ cpu_budget / reserved_grader_slots, 1 ].max
  end

  private

  attr_reader :run, :hostname

  def cpu_budget
    self.class.host_capacity
  end

  def concurrent_grader_count
    active = SpawnedProcess
      .where(hostname: hostname, finished_at: nil, kind: "grader")
      .where.not(run_id: run.id)
      .distinct
      .count(:run_id)
    active + 1
  end

  # Several grader Runs can be claimed by the same threaded Solid Queue worker
  # before any of them has registered its SpawnedProcess. Reserving against the
  # configured worker width closes that startup race: parallel test runners
  # cannot each claim the full host budget just because they started together.
  def reserved_grader_slots
    [ concurrent_grader_count, configured_job_concurrency ].max
  end

  def configured_job_concurrency
    Integer(ENV.fetch("JOB_CONCURRENCY", 3), 10).clamp(1, cpu_budget)
  rescue ArgumentError
    3.clamp(1, cpu_budget)
  end

  def self.cgroup_v2_cpu_count
    quota, period = File.read("/sys/fs/cgroup/cpu.max").split
    return if quota == "max"

    quota_count(quota, period)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def self.cgroup_v1_cpu_count
    quota = File.read("/sys/fs/cgroup/cpu/cpu.cfs_quota_us").strip
    return if quota.to_i <= 0

    period = File.read("/sys/fs/cgroup/cpu/cpu.cfs_period_us").strip
    quota_count(quota, period)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def self.quota_count(quota, period)
    return if period.to_f <= 0

    [ (quota.to_f / period.to_f).ceil, 1 ].max
  end

  def self.cgroup_v2_memory_limit
    value = File.read("/sys/fs/cgroup/memory.max").strip
    return if value == "max"

    positive_bytes(value)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def self.cgroup_v1_memory_limit
    positive_bytes(File.read("/sys/fs/cgroup/memory/memory.limit_in_bytes").strip)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def self.cgroup_v2_memory_working_set
    working_set_bytes(
      usage: File.read("/sys/fs/cgroup/memory.current").strip,
      stat: File.read("/sys/fs/cgroup/memory.stat")
    )
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def self.cgroup_v1_memory_working_set
    working_set_bytes(
      usage: File.read("/sys/fs/cgroup/memory/memory.usage_in_bytes").strip,
      stat: File.read("/sys/fs/cgroup/memory/memory.stat")
    )
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def self.working_set_bytes(usage:, stat:)
    usage_bytes = positive_bytes(usage)
    return unless usage_bytes

    inactive_file = stat[/^inactive_file\s+(\d+)$/, 1].to_i
    file = stat[/^(?:file|total_cache)\s+(\d+)$/, 1].to_i
    dirty = stat[/^(?:file_dirty|total_dirty)\s+(\d+)$/, 1].to_i
    writeback = stat[/^(?:file_writeback|total_writeback)\s+(\d+)$/, 1].to_i
    clean_file = [ file - dirty - writeback, 0 ].max
    reclaimable_file = [ inactive_file, clean_file ].max

    [ usage_bytes - reclaimable_file, 0 ].max
  end

  def self.proc_memory_total
    kibibytes = File.read("/proc/meminfo")[/^MemTotal:\s+(\d+)\s+kB$/, 1]
    positive_bytes(kibibytes.to_i * 1024)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def self.positive_bytes(value)
    bytes = value.to_i
    bytes if bytes.positive?
  end
end
