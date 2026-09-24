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
end
