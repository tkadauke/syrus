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

  validates :hostname, :role, :version, :started_at, presence: true

  scope :fresh, ->(threshold = HEARTBEAT_STALE_THRESHOLD) {
    running.where("last_heartbeat_at IS NULL AND started_at > :t OR last_heartbeat_at > :t", t: threshold.ago)
  }

  def seconds_since_heartbeat
    return nil if last_heartbeat_at.nil?
    (Time.current - last_heartbeat_at).round
  end

  def stale?(threshold = HEARTBEAT_STALE_THRESHOLD)
    return false if finished?
    return false if last_heartbeat_at.nil? && started_at && started_at > threshold.ago

    last_heartbeat_at.nil? || last_heartbeat_at < threshold.ago
  end
end
