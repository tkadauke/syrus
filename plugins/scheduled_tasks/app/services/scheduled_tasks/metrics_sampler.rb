module ScheduledTasks
  # A cache-mediated gauge counting Tasks currently auto-paused after hitting
  # AppSetting.max_job_failures, so a silently-stopped cron task shows up the
  # same way a stalled queue does (see Task#auto_pause!, "Auto-pause" in
  # docs/syrus_docs/scheduled_tasks.md).
  #
  # Sampled on the plugin's existing tick (Callbacks#on_tick, which already
  # fires every minute to drive PollScheduledTasksJob) rather than computed on
  # the /metrics scrape path directly: /metrics is served by the web role
  # only, but nothing about the current count is worker-specific, so this is
  # really about keeping every gauge on the same "sample on a timer into the
  # cache, never on the scrape path" discipline the rest of /metrics uses.
  class MetricsSampler
    CACHE_KEY = "scheduled_tasks:metrics:autopaused_count".freeze
    CACHE_TTL = 5.minutes

    def self.sample!
      count = Task.alive.where(state: "auto_paused").count
      Rails.cache.write(CACHE_KEY, count, expires_in: CACHE_TTL)
      count
    end

    def self.refresh_gauges!
      count = Rails.cache.read(CACHE_KEY)
      return false if count.nil?

      Syrus::Metrics.gauge(:syrus_scheduled_tasks_autopaused_total).set(count)
      true
    end
  end
end
