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
    ScheduledTasks::Task.alive
                 .where(state: "scheduled")
                 .joins(:repository).merge(Repository.active)
                 .joins(:user).where(users: { scheduling_paused: false })
                 .find_each do |task|
      next unless task.due?(now: now)

      result = ScheduledTasks::Fire.new(task, now: now, require_due: true).call
      if result.skipped
        Rails.logger.info("[PollScheduledTasksJob] task ##{task.id} skipped: #{result.reason}")
      else
        Rails.logger.info("[PollScheduledTasksJob] task ##{task.id} fired → #{result.job.slug}")
      end
    rescue StandardError => e
      begin
        task.record_fire_failure!(e, at: now)
      rescue StandardError => recording_error
        Rails.logger.error(
          "[PollScheduledTasksJob] task ##{task.id} failure record failed: " \
          "#{recording_error.class}: #{recording_error.message}"
        )
      end
      BackendExceptionLogging.ingest_job(
        { job: self, exception_object: e, exception: [ e.class.name, e.message ] },
        0
      )
      Rails.logger.warn("[PollScheduledTasksJob] task ##{task.id} fire failed: #{e.class}: #{e.message}")
    end
  end
end
