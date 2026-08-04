class PollScheduledTasksJob < ApplicationJob
  include SkipIfPending

  queue_as :control_plane

  # Recurring scheduler for ScheduledTask. Runs every minute, scans
  # alive+active tasks, hands the ones whose next scheduled time has
  # arrived to ScheduledTaskFire (which applies the pr_pileup_policy,
  # spawns the cron Job, and stamps last_fired_at).
  def perform
    return if AppSetting.polling_paused?
    now = Time.current
    ScheduledTask.alive
                 .where(state: "scheduled")
                 .joins(:repository).merge(Repository.active)
                 .joins(:user).where(users: { scheduling_paused: false })
                 .find_each do |task|
      next unless task.due?(now: now)

      result = ScheduledTaskFire.new(task, now: now, require_due: true).call
      if result.skipped
        Rails.logger.info("[PollScheduledTasksJob] task ##{task.id} skipped: #{result.reason}")
      else
        Rails.logger.info("[PollScheduledTasksJob] task ##{task.id} fired → #{result.job.slug}")
      end
    rescue StandardError => e
      Rails.logger.warn("[PollScheduledTasksJob] task ##{task.id} fire failed: #{e.class}: #{e.message}")
    end
  end
end
