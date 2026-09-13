module MetricsDashboard
  # Fires once a minute while the plugin is enabled and healthy (see
  # PluginTickSchedulerJob, which is what makes "disabled" actually stop the
  # recording rather than merely hide the page).
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      Recorder.record!
      PruneJob.perform_later if prune_due?
    rescue StandardError => e
      # A recorder that raises would mark the tick failed and, worse, could
      # retry into a loop. The dashboard losing one minute is not worth that.
      Rails.logger.warn("[MetricsDashboard] tick failed: #{e.class}: #{e.message}")
    end

    # Pruning is cheap but pointless every minute; once an hour keeps the table
    # inside its retention window without a second scheduler.
    def self.prune_due?
      Time.current.min.zero?
    end
  end
end
