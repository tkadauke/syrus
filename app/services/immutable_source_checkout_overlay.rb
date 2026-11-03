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
  #
  # `diagnostics` is a bounded, string-keyed hash explaining the outcome: the
  # command, exit status and trimmed stderr of both mount attempts plus the
  # environment facts that decide them (see .environment_diagnostics). It is
  # recorded on fallback Steps and in worker health so a fallback can be
  # explained without reading logs.
  Capability = Data.define(:strategy, :reason, :diagnostics) do
    def initialize(strategy:, reason:, diagnostics: {})
      super
    end

    def direct? = strategy == :direct

    def user_namespace? = strategy == :user_namespace

    def available? = direct?

    def to_h
      { "strategy" => strategy.to_s, "reason" => reason, "diagnostics" => diagnostics }
    end
  end

  STDERR_LIMIT = 500
  COMMAND_LIMIT = 300
  CAP_SYS_ADMIN_BIT = 21
  PERMISSION_DENIED = /operation not permitted|must be superuser|permission denied|EPERM|EACCES/i

  def self.capability(refresh: false)
    @capability = nil if refresh
    @capability ||= probe_capability
  end

  def self.probe_capability
    diagnostics = environment_diagnostics
    return build_capability(:unavailable, "overlayfs requires Linux workers", diagnostics) unless RbConfig::CONFIG.fetch("host_os").match?(/linux/i)
    unless overlay_filesystem_available?
      diagnostics["overlay_in_proc_filesystems"] = false
      return build_capability(:unavailable, "overlayfs is not listed in /proc/filesystems (kernel without overlay support)", diagnostics)
    end
    diagnostics["overlay_in_proc_filesystems"] = true

    Dir.mktmpdir("syrus-overlay-probe-") do |dir|
      probe = Pathname.new(dir)
      diagnostics["probe_dir_filesystem"] = filesystem_type(probe)
      %w[lower upper work mount].each { |name| FileUtils.mkdir_p(probe.join(name)) }
      options = "lowerdir=#{probe.join('lower')},upperdir=#{probe.join('upper')},workdir=#{probe.join('work')}"
      mount_point = probe.join("mount").to_s

      direct_command = [ "mount", "-t", "overlay", "overlay", "-o", options, mount_point ]
      direct = capture(direct_command, workdir: probe)
      diagnostics["direct"] = attempt_diagnostics(direct_command, direct)
      if direct.success?
        unmount(mount_point)
        next build_capability(:direct, nil, diagnostics)
      end

      namespace_command = [
        "unshare", "--user", "--map-root-user", "--mount", "--propagation", "unchanged",
        "sh", "-c", "mount -t overlay overlay -o #{options} #{mount_point}"
      ]
      namespace = capture(namespace_command, workdir: probe)
      diagnostics["user_namespace"] = attempt_diagnostics(namespace_command, namespace)
      reason = failure_reason(diagnostics, namespace_succeeded: namespace.success?)
      next build_capability(:user_namespace, reason, diagnostics) if namespace.success?

      build_capability(:unavailable, reason, diagnostics)
    end
  rescue StandardError => e
    build_capability(:unavailable, "overlay support probe failed: #{e.class}: #{e.message}", diagnostics || {})
  end

  def self.build_capability(strategy, reason, diagnostics)
    Capability.new(strategy: strategy, reason: reason, diagnostics: diagnostics)
  end

  def self.attempt_diagnostics(command, capture)
    {
      "command" => command.join(" ").truncate(COMMAND_LIMIT),
      "exit_status" => capture.result.exit_status,
      "stderr" => capture.stderr.to_s.strip.truncate(STDERR_LIMIT)
    }
  end

  # Names the actual blocking cause, e.g. "direct mount denied (EPERM: must be
  # superuser to use mount) and user-namespace mount denied: unprivileged user
  # namespaces disabled (max_user_namespaces=0)".
  def self.failure_reason(diagnostics, namespace_succeeded:)
    direct = describe_attempt("direct mount", diagnostics.fetch("direct"))
    if namespace_succeeded
      return "overlay mount failed: #{direct}; user-namespace mount works"
    end

    namespace = describe_attempt("user-namespace mount", diagnostics.fetch("user_namespace"))
    cause = namespace_blocker(diagnostics)
    "overlay mount failed: #{direct} and #{namespace}#{cause ? ": #{cause}" : ""}"
  end

  def self.describe_attempt(label, attempt)
    stderr = attempt["stderr"].presence
    detail = stderr || "exit #{attempt['exit_status']}"
    if stderr&.match?(PERMISSION_DENIED)
      "#{label} denied (EPERM: #{detail})"
    else
      "#{label} failed (#{detail})"
    end
  end

  def self.namespace_blocker(diagnostics)
    return "unshare binary missing" if diagnostics["unshare_available"] == false
    return "mount binary missing" if diagnostics["mount_available"] == false
    return "unprivileged user namespaces disabled (max_user_namespaces=0)" if diagnostics["max_user_namespaces"] == 0
    return "unprivileged user namespaces disabled (kernel.unprivileged_userns_clone=0)" if diagnostics["unprivileged_userns_clone"] == 0
    return "unprivileged user namespaces restricted (apparmor_restrict_unprivileged_userns=1)" if diagnostics["apparmor_restrict_unprivileged_userns"] == 1
    return "no CAP_SYS_ADMIN and user namespace unavailable (seccomp/AppArmor profile or nested overlayfs on #{diagnostics['probe_dir_filesystem'] || 'unknown'} suspected)" if diagnostics["cap_sys_admin"] == false

    nil
  end

  # Environment facts that decide whether a mount can work. Every value is a
  # scalar, read best-effort; nothing here is sensitive.
  def self.environment_diagnostics
    {
      "effective_uid" => Process.euid,
      "cap_sys_admin" => cap_sys_admin?,
      "max_user_namespaces" => read_integer("/proc/sys/user/max_user_namespaces"),
      "unprivileged_userns_clone" => read_integer("/proc/sys/kernel/unprivileged_userns_clone"),
      "apparmor_restrict_unprivileged_userns" => read_integer("/proc/sys/kernel/apparmor_restrict_unprivileged_userns"),
      "mount_available" => executable_on_path?("mount"),
      "unshare_available" => executable_on_path?("unshare"),
      "workspace_root_filesystem" => workspace_root_filesystem
    }.compact
  end

  def self.workspace_root_filesystem
    filesystem_type(WorkflowWorkspace.data_root)
  rescue StandardError
    nil
  end

  def self.cap_sys_admin?
    line = File.readlines("/proc/self/status").find { |l| l.start_with?("CapEff:") }
    return nil unless line

    line.split.last.to_i(16)[CAP_SYS_ADMIN_BIT] == 1
  rescue SystemCallError
    nil
  end

  def self.read_integer(path)
    Integer(File.read(path).strip, 10)
  rescue SystemCallError, ArgumentError
    nil
  end

  def self.executable_on_path?(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      candidate = File.join(dir, name)
      File.file?(candidate) && File.executable?(candidate)
    end
  end

  # Filesystem type of the mount containing `path`: the longest mountpoint
  # prefix in /proc/self/mountinfo.
  def self.filesystem_type(path)
    target = Pathname.new(path).expand_path.to_s
    best = nil
    File.readlines("/proc/self/mountinfo", chomp: true).each do |line|
      head, tail = line.split(" - ", 2)
      next unless tail

      mountpoint = head.split[4].to_s.gsub("\\040", " ")
      next unless target == mountpoint || target.start_with?(mountpoint.chomp("/") + "/")

      best = [ mountpoint, tail.split.first ] if best.nil? || mountpoint.length > best[0].length
    end
    best&.last
  rescue SystemCallError
    nil
  end

  def self.overlay_filesystem_available?
    File.read("/proc/filesystems").lines.any? { |line| line.split.last == "overlay" }
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def self.capture(command, workdir:)
    ProcessRunner.new(
      env: {}, command: command, mounts: ProcessRunner.mounts(workdir),
      network: "grader", timeout: 2.minutes, kind: "filesystem"
    ).capture
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
    capture = capture([ "umount", path.to_s ], workdir: Pathname.new(path).dirname)
    message = capture.stderr.presence || capture.stdout.presence
    if capture.success?
      log&.call("[immutable_source_checkout] unmounted overlay workspace #{path}")
      true
    else
      log&.call("[immutable_source_checkout] overlay workspace unmount failed for #{path}: #{message || capture.result.exit_status}")
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

    capture = self.class.capture(
      [ "mount", "-t", "overlay", "overlay", "-o", mount_options, mount_path.to_s ],
      workdir: mount_path.dirname
    )
    return mounted_result if capture.success?

    FileUtils.rm_rf(mount_path.to_s)
    fallback("overlay mount failed: #{(capture.stderr.presence || capture.stdout.presence || capture.result.exit_status).to_s.strip}")
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
