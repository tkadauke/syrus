require "open3"
require "rbconfig"

class ImmutableSourceCheckoutOverlay
  Result = Data.define(:mounted, :reason, :lower_path, :upper_path, :work_path, :mount_path) do
    def mounted? = mounted

    def strategy = mounted ? "overlay" : "copy"
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
    return "overlayfs requires Linux workers" unless linux?
    return "overlayfs is not listed in /proc/filesystems" unless overlay_filesystem_available?
    return "prepared checkout lower directory is missing" unless lower_path.directory?

    nil
  end

  def linux?
    RbConfig::CONFIG.fetch("host_os").match?(/linux/i)
  end

  def overlay_filesystem_available?
    File.read("/proc/filesystems").lines.any? { |line| line.split.last == "overlay" }
  rescue Errno::ENOENT, Errno::EACCES
    false
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
    log&.call("[immutable_source_checkout] overlay workspace unavailable; falling back to copy: #{reason}")
    Result.new(false, reason, lower_path.to_s, upper_path.to_s, work_path.to_s, mount_path.to_s)
  end
end
