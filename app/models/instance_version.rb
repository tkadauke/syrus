# One row per running Rails process (web pod or worker pod). The
# row is created on boot, heartbeated every 30s by
# InstanceVersionSupervisor, and finalized at process exit. The
# /api/v1/admin/version endpoint returns the rows with fresh
# heartbeats; the supervisor + recurring reaper finalize stale rows
# so the table doesn't bloat.
#
# The "instance" key is (hostname, role) — K8s pod names are unique,
# so a single pod registers exactly one row per role it runs (each
# pod runs one role today). Multiple Puma worker processes on the
# same pod register only once: the unique index makes the second+
# inserts fail silently via insert_with_save's rescue, and they all
# share the row's heartbeat thread (started in the master).
class InstanceVersion < ApplicationRecord
  include TracksFinishedAt

  ROLES = %w[ web worker local ].freeze
  HEARTBEAT_STALE_THRESHOLD = 2.minutes
  REAPER_STALE_THRESHOLD = 5.minutes
  MACOS_UPDATER_STALE_THRESHOLD = 15.minutes

  before_validation :default_capability_payloads

  validates :hostname, :role, :version, :started_at, presence: true

  scope :fresh, ->(threshold = HEARTBEAT_STALE_THRESHOLD) {
    running.where("last_heartbeat_at IS NULL AND started_at > :t OR last_heartbeat_at > :t", t: threshold.ago)
  }

  # True when a worker pod with this hostname is currently alive (fresh
  # heartbeat). Used to decide whether a "Retry from failed step" can be routed
  # back to the worker that holds the Job's workspace; if the pod is gone, the
  # caller falls back to a fresh clone on any worker. Returns false when
  # instance tracking is inactive (local/dev, where SYRUS_ROLE is unset and no
  # rows exist), so resume routing degrades to the normal queue.
  def self.worker_live?(hostname)
    return false if hostname.blank?

    fresh.where(hostname: hostname, role: "worker").exists?
  end

  def self.worker_queue_live?(queue_name)
    return false if queue_name.blank?

    SolidQueue::Process.where.not(last_heartbeat_at: nil).any? do |process|
      next false unless process.last_heartbeat_at >= HEARTBEAT_STALE_THRESHOLD.ago

      queue_names(process.metadata&.dig("queues")).include?(queue_name.to_s)
    end
  rescue NameError, ActiveRecord::StatementInvalid
    false
  end

  def self.queue_names(raw)
    case raw
    when Array
      raw.flat_map { |entry| queue_names(entry) }
    else
      raw.to_s.split(/[,\s]+/)
    end.compact_blank
  end

  # ----- per-pod SYRUS_DATA_ROOT usage --------------------------------------
  # Stamped by the heartbeat on worker pods (InstanceVersionSupervisor). Under
  # local-disk multi-worker each pod fills independently, so disk health is
  # per-pod rather than a single shared reading.

  # The worker pod with the most-alarming data-root usage right now (fresh
  # heartbeat, usage recorded). Critical / near-full sorts first.
  def self.worst_data_root
    fresh.where(role: "worker").where.not(data_root_used_percent: nil)
         .order(data_root_used_percent: :desc, data_root_available_bytes: :asc)
         .first
  end

  def self.worker_data_root_usages
    fresh.where(role: "worker").where.not(data_root_used_percent: nil)
         .order(data_root_used_percent: :desc)
         .map(&:data_root_usage_json)
  end

  def data_root_alert_level
    return nil if data_root_used_percent.nil?
    if data_root_used_percent >= DataRootDiskUsage::CRITICAL_USED_PERCENT ||
       (data_root_available_bytes && data_root_available_bytes < DataRootDiskUsage::CRITICAL_AVAILABLE_BYTES)
      return :critical
    end
    return :warning if data_root_used_percent >= DataRootDiskUsage::WARNING_USED_PERCENT

    :ok
  end

  def data_root_alert?
    level = data_root_alert_level
    !level.nil? && level != :ok
  end

  def data_root_usage_json
    return nil if data_root_used_percent.nil?

    {
      hostname: hostname,
      path: data_root_path,
      used_percent: data_root_used_percent,
      available_bytes: data_root_available_bytes,
      total_bytes: data_root_total_bytes,
      level: data_root_alert_level.to_s,
      observed_at: last_heartbeat_at&.iso8601
    }
  end

  def seconds_since_heartbeat
    return nil if last_heartbeat_at.nil?
    (Time.current - last_heartbeat_at).round
  end

  def stale?(threshold = HEARTBEAT_STALE_THRESHOLD)
    return false if finished?
    return false if last_heartbeat_at.nil? && started_at && started_at > threshold.ago

    last_heartbeat_at.nil? || last_heartbeat_at < threshold.ago
  end

  def macos_updater_state
    status = macos_updater_status || {}
    desired = desired_version || status["desired"] || {}
    state = status["state"].presence || "unknown"
    observed_at = parse_updater_time(status["observed_at"])

    return "stale" if observed_at && observed_at < MACOS_UPDATER_STALE_THRESHOLD.ago
    return "current" if desired["git_sha"].present? && desired["git_sha"].to_s == version.to_s && state != "failed"

    state
  end

  private

  def default_capability_payloads
    self.capabilities ||= {}
    self.capability_diagnostics ||= {}
    self.desired_version ||= {}
    self.macos_updater_status ||= {}
  end

  def parse_updater_time(value)
    return value if value.respond_to?(:to_time)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
