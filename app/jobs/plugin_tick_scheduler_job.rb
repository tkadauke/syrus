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
    cutoff = now - interval

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
