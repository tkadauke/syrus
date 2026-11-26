require "etc"
require "fileutils"
require "securerandom"

# Whether this worker can build the cgroup tree adaptive resource control
# needs: its own process fenced into a `control/` child and every workload in
# children of a `workloads/` sibling, each with limits the worker rewrites.
#
# Read-mostly by design -- it creates and removes one empty child cgroup and
# never moves a process or changes `cgroup.subtree_control`, so running it on
# every worker changes nothing. Published with the worker's capabilities.
class CgroupDelegationProbe
  CONTROLLERS = %w[cpu memory io].freeze

  def self.capability(refresh: false)
    @capability = nil if refresh
    @capability ||= new.call
  end

  def initialize(cgroup_path: nil)
    @cgroup_path = cgroup_path
  end

  def call
    return result("unavailable", "not a Linux worker") unless linux? || @cgroup_path
    return result("unavailable", "no cgroup v2 hierarchy is mounted") unless cgroup_path && File.directory?(cgroup_path)

    available = read_words("cgroup.controllers")
    missing = CONTROLLERS - available
    return result("unavailable", "controllers missing from this cgroup: #{missing.join(', ')}", available:) if missing.any?

    child_error = create_child_error
    return result("read_only", "cannot create a child cgroup: #{child_error}", available:) if child_error

    process_count = read_lines("cgroup.procs").size
    if process_count.positive?
      return result("needs_control_move",
        "#{process_count} process(es) live in this cgroup; they must move into a control/ child before " \
        "controllers can be enabled for children", available:, process_count:)
    end

    result("ready", "child cgroups can be created and controlled", available:, process_count:)
  end

  private

  def result(state, reason, available: [], process_count: nil)
    {
      "state" => state,
      "reason" => reason,
      "cgroup_path" => cgroup_path,
      "available_controllers" => available,
      "subtree_control" => cgroup_path ? read_words("cgroup.subtree_control") : [],
      "process_count" => process_count,
      "procs_writable" => cgroup_path ? File.writable?(File.join(cgroup_path, "cgroup.procs")) : false
    }.compact
  end

  def create_child_error
    probe = File.join(cgroup_path, ".syrus-delegation-probe-#{Process.pid}-#{SecureRandom.hex(4)}")
    Dir.mkdir(probe)
    nil
  rescue SystemCallError => e
    e.class.name.split("::").last
  ensure
    Dir.rmdir(probe) if probe && File.directory?(probe)
  end

  def read_words(file) = read(file).split

  def read_lines(file) = read(file).lines.map(&:strip).reject(&:empty?)

  def read(file)
    File.read(File.join(cgroup_path, file))
  rescue SystemCallError
    ""
  end

  def cgroup_path
    @cgroup_path ||= begin
      mount = cgroup_v2_mount
      relative = self_cgroup_relative_path
      File.expand_path(".#{relative}", mount) if mount && relative
    end
  end

  def cgroup_v2_mount
    File.foreach("/proc/self/mountinfo") do |line|
      pre, post = line.split(" - ", 2)
      return pre.split[4] if post&.split&.first == "cgroup2"
    end
    nil
  rescue SystemCallError
    nil
  end

  def self_cgroup_relative_path
    File.foreach("/proc/self/cgroup") do |line|
      hierarchy, controllers, path = line.chomp.split(":", 3)
      return path if hierarchy == "0" && controllers == ""
    end
    nil
  rescue SystemCallError
    nil
  end

  def linux?
    Etc.uname[:sysname] == "Linux"
  rescue StandardError
    false
  end
end
