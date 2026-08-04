# Cleans up instance_versions rows whose pod died ungracefully (no
# at_exit hook fired, no graceful SIGTERM finalize). The supervisor's
# 30s heartbeat means a row that hasn't been touched in 5+ minutes is
# definitively gone — most likely SIGKILLed by a deploy or evicted by
# K8s. We stamp finished_at = last_heartbeat_at (the moment we last
# heard from it) and outcome = "stale".
#
# The /api/v1/admin/version endpoint already filters by freshness on
# the read path, so stale rows wouldn't appear there even without
# this job. The reaper exists so the table doesn't grow unboundedly
# and so the closed rows have a clean closure-time we can audit later.
class ReapStaleInstanceVersionsJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    cutoff = InstanceVersion::REAPER_STALE_THRESHOLD.ago

    InstanceVersion.running
      .where("last_heartbeat_at IS NULL AND started_at < :t OR last_heartbeat_at < :t", t: cutoff)
      .find_each do |iv|
        finalized_at = iv.last_heartbeat_at || iv.started_at || Time.current

        rows = InstanceVersion.where(id: iv.id, finished_at: nil)
                              .update_all(finished_at: finalized_at, outcome: "stale")
        next if rows.zero?

        Rails.logger.info("[ReapStaleInstanceVersionsJob] finalized InstanceVersion ##{iv.id} (#{iv.role}/#{iv.hostname} v#{iv.version}) — heartbeat stopped at #{finalized_at.iso8601}")
      end
  end
end
