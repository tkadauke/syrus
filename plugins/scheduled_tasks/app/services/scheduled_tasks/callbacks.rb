module ScheduledTasks
  # Drives the poll that fires due schedules.
  #
  # This was an entry in the host's config/recurring.yml, which is not
  # something a plugin can add. `tick_interval` plus this callback is the
  # plugin-owned equivalent, and it stops when the plugin is disabled --
  # which the YAML entry never did.
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      PollScheduledTasksJob.perform_later
      sample_metrics
    end

    def self.on_metrics_scrape
      MetricsSampler.refresh_gauges!
    end

    def self.sample_metrics
      MetricsSampler.sample!
    rescue StandardError => e
      Rails.logger.warn("[ScheduledTasks] metrics sample failed: #{e.class}: #{e.message}")
    end
    private_class_method :sample_metrics
  end
end
