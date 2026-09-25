require "etc"

class RunProcessParallelism
  CPU_UTILIZATION = 0.8

  def self.for(...) = new(...).call

  def self.host_capacity
    [ (effective_cpu_count * CPU_UTILIZATION).floor, 1 ].max
  end

  def self.effective_cpu_count
    cgroup_v2_cpu_count || cgroup_v1_cpu_count || Etc.nprocessors
  end

  def self.effective_memory_limit_bytes
    limits = [ cgroup_v2_memory_limit, cgroup_v1_memory_limit, proc_memory_total ].compact
    limits.min
  end

  def self.current_memory_bytes
    cgroup_v2_memory_working_set || cgroup_v1_memory_working_set
  end

  def initialize(run:, hostname: SyrusVersion.hostname)
    @run = run
    @hostname = hostname
  end

  def call
    [ cpu_budget / concurrent_grader_count, 1 ].max
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
    [ usage_bytes - inactive_file, 0 ].max
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
