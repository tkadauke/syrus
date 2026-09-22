# Fires each enabled plugin's `on_tick` callback on the cadence its manifest
# declares via `tick_interval`.
#
# Before this existed, `tick_interval` was stored on the manifest and read by
# nothing: PluginTickJob had no scheduler, so no bundled plugin's on_tick ever
# ran in production, including tailscale's, which declares 30 seconds. A plugin
# that wanted recurring work had to be added to the host's config/recurring.yml
# by hand, which is not something a plugin can do.
class PluginTickSchedulerJob < ApplicationJob
  include SkipIfPending

  queue_as :control_plane

  # This job runs once a minute (config/recurring.yml), and never at exactly
  # the same offset: a run that starts a few hundred milliseconds earlier than
  # the last one found only 59.6s elapsed, missed a strict `interval` cutoff,
  # and left the plugin for another full minute. Every 1-minute tick in fact
  # fired every other minute -- ~90s on average, which the metrics dashboard
  # had measured and sized its buckets around. A claim therefore needs only
  # `interval - SLACK` to have passed (at most half the interval, so a short
  # interval can never tick twice in one of its own periods).
  SLACK = 10.seconds

  def perform
    Syrus::PluginRegistry.all_plugins.each do |manifest|
      interval = manifest.tick_interval
      next if interval.blank?
      next unless manifest.enabled?
      next unless Syrus::PluginRegistry.health.healthy?(manifest.name)
      next if Array(manifest.provides[:callbacks]).empty?

      enqueue_tick(manifest, interval)
    end
  end

  private

  # Claim the tick with a conditional UPDATE so overlapping scheduler runs on
  # different workers cannot both fire the same interval.
  def enqueue_tick(manifest, interval)
    now = Time.current
    cutoff = now - interval + [ SLACK, interval / 2 ].min

    claimed = PluginRecord
      .where(name: manifest.name)
      .where("last_ticked_at IS NULL OR last_ticked_at <= ?", cutoff)
      .update_all(last_ticked_at: now)

    return if claimed.zero?

    queue = manifest.home_queue == :default ? PluginTickJob.queue_name : manifest.home_queue.to_s
    PluginTickJob.set(queue: queue).perform_later(manifest.name)
  rescue StandardError => e
    Rails.logger.error("[PluginTickSchedulerJob] #{manifest.name}: #{e.class}: #{e.message}")
  end
end
