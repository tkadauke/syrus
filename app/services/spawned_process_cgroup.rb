require "fileutils"
require "securerandom"

class SpawnedProcessCgroup
  VERSION = 1
  DEFAULT_MEMORY_MAX_FRACTION = 0.75
  DEFAULT_MEMORY_HIGH_FRACTION = 0.9
  DEFAULT_SWAP_MAX_BYTES = 0
  CLEANUP_WAIT_SECONDS = 5.0
  CLEANUP_POLL_SECONDS = 0.05

  attr_reader :state

  def initialize(spawned_process:)
    @spawned_process = spawned_process
    @state = "pending"
    @reason = nil
    @path = nil
    @memory_high_bytes = nil
    @memory_max_bytes = nil
    @memory_swap_max_bytes = nil
    @memory_events_before = {}
    @memory_events_after = {}
    @memory_peak_bytes = nil
    @cpu_stat = {}
    @io_stat = {}
    @cleanup = nil

    prepare
  end

  def attach!(pid)
    return unless state == "ready"

    File.write(File.join(path, "cgroup.procs"), pid.to_s)
    @state = "applied"
  rescue StandardError => e
    @state = "failed"
    @reason = "failed to attach pid to cgroup: #{e.class}: #{e.message}"
    cleanup!
  end

  def sample_exit!
    return unless path

    @memory_events_after = read_key_value_file("memory.events")
    @memory_peak_bytes = read_integer_file("memory.peak")
    @cpu_stat = read_key_value_file("cpu.stat")
    @io_stat = read_io_stat
  rescue StandardError => e
    @reason ||= "failed to read cgroup exit counters: #{e.class}: #{e.message}"
  end

  def cleanup!
    return unless path

    wait_for_empty_cgroup unless fake_cgroup_parent?
    Dir.rmdir(path)
    @cleanup = "removed"
  rescue Errno::ENOENT
    @cleanup = "already_removed"
  rescue Errno::ENOTEMPTY
    raise unless fake_cgroup_parent?

    FileUtils.rm_rf(path)
    @cleanup = "removed"
  rescue StandardError => e
    @cleanup = "failed"
    @reason ||= "failed to clean up cgroup: #{e.class}: #{e.message}"
  end

  def payload
    {
      "version" => VERSION,
      "state" => state,
      "reason" => reason,
      "path" => relative_payload_path,
      "memory_high_bytes" => memory_high_bytes,
      "memory_max_bytes" => memory_max_bytes,
      "memory_swap_max_bytes" => memory_swap_max_bytes,
      "memory_oom_group" => state.in?(%w[ready applied]),
      "memory_events" => memory_events_delta.presence || memory_events_after.presence,
      "memory_events_before" => memory_events_before.presence,
      "memory_events_after" => memory_events_after.presence,
      "memory_peak_bytes" => memory_peak_bytes,
      "cpu_stat" => cpu_stat.presence,
      "io_stat" => io_stat.presence,
      "cleanup" => cleanup
    }.compact
  end

  def oom_kill?
    memory_events_delta.fetch("oom_kill", 0).positive? ||
      memory_events_after.fetch("oom_kill", 0).positive?
  end

  private

  attr_reader :spawned_process, :reason, :path, :memory_high_bytes, :memory_max_bytes,
              :memory_swap_max_bytes, :memory_events_before, :memory_events_after,
              :memory_peak_bytes, :cpu_stat, :io_stat, :cleanup

  def prepare
    unless Feature.per_spawn_resource_limits_enabled?
      @state = "disabled"
      @reason = "per_spawn_resource_limits feature flag is disabled"
      return
    end

    parent = parent_cgroup_path
    unless parent
      @state = "unavailable"
      @reason = "cgroup v2 parent could not be detected"
      return
    end

    unless memory_controller_available?(parent)
      @state = "unavailable"
      @reason = "memory controller is not available in the parent cgroup"
      return
    end

    @memory_max_bytes = configured_bytes("SYRUS_SPAWN_MEMORY_MAX_BYTES") || default_memory_max_bytes
    unless memory_max_bytes&.positive?
      @state = "unavailable"
      @reason = "no finite memory ceiling is configured or detectable"
      return
    end

    @memory_high_bytes = configured_bytes("SYRUS_SPAWN_MEMORY_HIGH_BYTES") ||
      (memory_max_bytes * DEFAULT_MEMORY_HIGH_FRACTION).floor
    @memory_swap_max_bytes = configured_bytes("SYRUS_SPAWN_MEMORY_SWAP_MAX_BYTES", allow_zero: true)
    @memory_swap_max_bytes = DEFAULT_SWAP_MAX_BYTES if memory_swap_max_bytes.nil?

    @path = File.join(parent, "syrus-spawned-process-#{spawned_process.id}-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(path)
    write_limit("memory.oom.group", 1)
    write_limit("memory.high", memory_high_bytes)
    write_limit("memory.max", memory_max_bytes)
    write_limit("memory.swap.max", memory_swap_max_bytes)
    @memory_events_before = read_key_value_file("memory.events")
    @state = "ready"
  rescue StandardError => e
    @state = "failed"
    @reason = "failed to prepare cgroup: #{e.class}: #{e.message}"
    cleanup!
  end

  def parent_cgroup_path
    override = ENV["SYRUS_SPAWN_CGROUP_PARENT"].presence
    return override if override && File.directory?(override)

    mount = cgroup_v2_mount
    relative = self_cgroup_relative_path
    return unless mount && relative

    File.expand_path(".#{relative}", mount)
  end

  def cgroup_v2_mount
    File.foreach("/proc/self/mountinfo") do |line|
      pre, post = line.split(" - ", 2)
      next unless post&.split&.first == "cgroup2"

      fields = pre.split
      return fields[4]
    end
    nil
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def self_cgroup_relative_path
    File.foreach("/proc/self/cgroup") do |line|
      hierarchy, controllers, path = line.chomp.split(":", 3)
      return path if hierarchy == "0" && controllers == ""
    end
    nil
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def memory_controller_available?(parent)
    controllers = File.read(File.join(parent, "cgroup.controllers")).split
    controllers.include?("memory")
  rescue Errno::ENOENT
    File.exist?(File.join(parent, "memory.max"))
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

  def default_memory_max_bytes
    limit = RunProcessParallelism.effective_memory_limit_bytes
    return unless limit&.positive?

    (limit * DEFAULT_MEMORY_MAX_FRACTION).floor
  end

  def write_limit(file, value)
    File.write(File.join(path, file), value.to_s)
  end

  def read_key_value_file(file)
    full_path = File.join(path, file)
    return {} unless File.exist?(full_path)

    File.readlines(full_path).each_with_object({}) do |line, values|
      key, value = line.split(/\s+/, 2)
      next if key.blank? || value.blank?

      values[key] = Integer(value, 10)
    rescue ArgumentError
      next
    end
  end

  def read_io_stat
    full_path = File.join(path, "io.stat")
    return {} unless File.exist?(full_path)

    File.readlines(full_path).each_with_object({}) do |line, devices|
      device, *pairs = line.split
      next if device.blank?

      devices[device] = pairs.each_with_object({}) do |pair, values|
        key, value = pair.split("=", 2)
        values[key] = Integer(value, 10) if key.present? && value.present?
      rescue ArgumentError
        next
      end
    end
  end

  def read_integer_file(file)
    full_path = File.join(path, file)
    return nil unless File.exist?(full_path)

    value = File.read(full_path).strip
    return nil if value.blank? || value == "max"

    Integer(value, 10)
  rescue ArgumentError
    nil
  end

  def memory_events_delta
    keys = memory_events_before.keys | memory_events_after.keys
    keys.each_with_object({}) do |key, delta|
      before = memory_events_before.fetch(key, 0)
      after = memory_events_after.fetch(key, 0)
      value = after - before
      delta[key] = value if value.positive?
    end
  end

  def wait_for_empty_cgroup
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CLEANUP_WAIT_SECONDS
    while File.exist?(File.join(path, "cgroup.procs")) && File.read(File.join(path, "cgroup.procs")).present?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep CLEANUP_POLL_SECONDS
    end
  rescue Errno::ENOENT
    nil
  end

  def relative_payload_path
    return unless path

    root = ENV["SYRUS_SPAWN_CGROUP_PARENT"].presence
    return File.basename(path) if root && path.start_with?(root)

    path
  end

  def fake_cgroup_parent?
    root = ENV["SYRUS_SPAWN_CGROUP_PARENT"].presence
    root && path.start_with?(File.expand_path(root))
  end
end
