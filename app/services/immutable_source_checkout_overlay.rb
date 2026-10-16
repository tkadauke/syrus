require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

class ImmutableSourceCheckoutOverlay
  Result = Data.define(:mounted, :reason, :lower_path, :upper_path, :work_path, :mount_path) do
    def mounted? = mounted

    def strategy = mounted ? "overlay" : "copy"
  end

  # What this worker can actually do, probed once per process.
  #
  # The support check used to be "Linux, and overlay is in /proc/filesystems",
  # which cannot see the thing that actually stops the mount: an unprivileged
  # container has no effective CAP_SYS_ADMIN, so `mount` is refused with
  # "must be superuser to use mount". On a stock Kubernetes worker that made
  # every single materialization attempt a failed mount plus a misleading log
  # line -- 2,232 of them in one production day -- before falling back.
  #
  # The probe also records whether a mount inside a user namespace would work
  # (kernels 5.11+ allow unprivileged overlayfs there; `unshare` needs
  # --propagation unchanged, since remounting / private is itself privileged).
  # Nothing uses that strategy yet: the mount would live in the namespace, so
  # the graded command has to execute inside it, which is a change to how
  # commands are run rather than to how workspaces are materialized. Recording
  # it says whether the fleet is ready for that work.
  Capability = Data.define(:strategy, :reason) do
    def direct? = strategy == :direct

    def user_namespace? = strategy == :user_namespace

    def available? = direct?
  end

  def self.capability(refresh: false)
    @capability = nil if refresh
    @capability ||= probe_capability
  end

  def self.probe_capability
    return Capability.new(:unavailable, "overlayfs requires Linux workers") unless RbConfig::CONFIG.fetch("host_os").match?(/linux/i)
    return Capability.new(:unavailable, "overlayfs is not listed in /proc/filesystems") unless overlay_filesystem_available?

    Dir.mktmpdir("syrus-overlay-probe-") do |dir|
      probe = Pathname.new(dir)
      %w[lower upper work mount].each { |name| FileUtils.mkdir_p(probe.join(name)) }
      options = "lowerdir=#{probe.join('lower')},upperdir=#{probe.join('upper')},workdir=#{probe.join('work')}"
      mount_point = probe.join("mount").to_s

      _out, direct_error, direct_status = Open3.capture3("mount", "-t", "overlay", "overlay", "-o", options, mount_point)
      if direct_status.success?
        unmount(mount_point)
        next Capability.new(:direct, nil)
      end

      _ns_out, _ns_error, ns_status = Open3.capture3(
        "unshare", "--user", "--map-root-user", "--mount", "--propagation", "unchanged",
        "sh", "-c", "mount -t overlay overlay -o #{options} #{mount_point}"
      )
      reason = "overlay mount failed: #{direct_error.to_s.strip.presence || "exit #{direct_status.exitstatus}"}"
      next Capability.new(:user_namespace, reason) if ns_status.success?

      Capability.new(:unavailable, reason)
    end
  rescue StandardError => e
    Capability.new(:unavailable, "overlay support probe failed: #{e.class}: #{e.message}")
  end

  def self.overlay_filesystem_available?
    File.read("/proc/filesystems").lines.any? { |line| line.split.last == "overlay" }
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.mount(...)
    new(...).mount
  end

  def self.unmounts_under(root, log: nil)
    root = Pathname.new(root)
    return [] unless root.directory?

    mountpoints_under(root).map do |mountpoint|
      unmount(mountpoint, log: log)
    end
  end

  def self.mountpoints_under(root)
    root = Pathname.new(root).expand_path
    return [] unless File.readable?("/proc/self/mountinfo")

    File.readlines("/proc/self/mountinfo", chomp: true).filter_map do |line|
      mountpoint = line.split(" - ", 2).first.to_s.split[4]
      next if mountpoint.blank?

      path = Pathname.new(mountpoint).expand_path
      path if path.to_s == root.to_s || path.to_s.start_with?("#{root}/")
    rescue ArgumentError
      nil
    end.sort_by { |path| -path.to_s.length }
  rescue Errno::ENOENT
    []
  end

  def self.unmount(path, log: nil)
    stdout, stderr, status = Open3.capture3("umount", path.to_s)
    message = stderr.presence || stdout.presence
    if status.success?
      log&.call("[immutable_source_checkout] unmounted overlay workspace #{path}")
      true
    else
      log&.call("[immutable_source_checkout] overlay workspace unmount failed for #{path}: #{message || status.exitstatus}")
      false
    end
  end

  def initialize(lower_path:, mount_path:, log: nil)
    @lower_path = Pathname.new(lower_path)
    @mount_path = Pathname.new(mount_path)
    @log = log
  end

  def mount
    unsupported = unsupported_reason
    return fallback(unsupported) if unsupported

    FileUtils.rm_rf(mount_path.to_s)
    FileUtils.mkdir_p(upper_path)
    FileUtils.mkdir_p(work_path)
    FileUtils.mkdir_p(mount_path)

    stdout, stderr, status = Open3.capture3("mount", "-t", "overlay", "overlay", "-o", mount_options, mount_path.to_s)
    return mounted_result if status.success?

    FileUtils.rm_rf(mount_path.to_s)
    fallback("overlay mount failed: #{(stderr.presence || stdout.presence || status.exitstatus).to_s.strip}")
  rescue SystemCallError => e
    FileUtils.rm_rf(mount_path.to_s)
    fallback("overlay mount failed: #{e.class}: #{e.message}")
  end

  private

  attr_reader :lower_path, :mount_path, :log

  def unsupported_reason
    capability = self.class.capability
    return capability.reason unless capability.available?
    return "prepared checkout lower directory is missing" unless lower_path.directory?

    nil
  end

  def mount_options
    "lowerdir=#{lower_path},upperdir=#{upper_path},workdir=#{work_path}"
  end

  def upper_path
    overlay_root.join("upper")
  end

  def work_path
    overlay_root.join("work")
  end

  def overlay_root
    mount_path.dirname.join(".#{mount_path.basename}.overlay")
  end

  def mounted_result
    log&.call("[immutable_source_checkout] overlay workspace mounted at #{mount_path} with lower #{lower_path}")
    Result.new(true, nil, lower_path.to_s, upper_path.to_s, work_path.to_s, mount_path.to_s)
  end

  def fallback(reason)
    capability = self.class.capability
    note = capability.user_namespace? ? " (a user-namespace mount is available on this host; wrapping graded commands in one is not implemented yet)" : ""
    log&.call("[immutable_source_checkout] overlay workspace unavailable; falling back without it: #{reason}#{note}")
    Result.new(false, reason, lower_path.to_s, upper_path.to_s, work_path.to_s, mount_path.to_s)
  end
end
