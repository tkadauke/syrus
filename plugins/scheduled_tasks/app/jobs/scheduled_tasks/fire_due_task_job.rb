module ScheduledTasks
  class FireDueTaskJob < PluginJob
    plugin :scheduled_tasks
    queue_as :polling

    def perform(task, now)
      result = Fire.new(task, now: now, require_due: true).call
      if result.skipped
        Rails.logger.info("[ScheduledTasks::FireDueTaskJob] task ##{task.id} skipped: #{result.reason}")
      else
        Rails.logger.info("[ScheduledTasks::FireDueTaskJob] task ##{task.id} fired → #{result.job.slug}")
      end
    rescue StandardError => e
      record_failure(task, e, now)
    end

    private

    def record_failure(task, error, now)
      begin
        due_at = task.reload.fire_window_start(now: now, manual: false)
        task.with_lock do
          task.record_fire_failure!(error, at: now)
          record_failed_occurrence(task, due_at: due_at, attempted_at: now) if due_at
        end
      rescue StandardError => recording_error
        Rails.logger.error(
          "[ScheduledTasks::FireDueTaskJob] task ##{task.id} failure record failed: " \
          "#{recording_error.class}: #{recording_error.message}"
        )
      end
      BackendExceptionLogging.ingest_job(
        { job: self, exception_object: error, exception: [ error.class.name, error.message ] },
        0
      )
      Rails.logger.warn(
        "[ScheduledTasks::FireDueTaskJob] task ##{task.id} fire failed: #{error.class}: #{error.message}"
      )
    end

    def record_failed_occurrence(task, due_at:, attempted_at:)
      occurrence = task.occurrences.find_or_create_by!(due_at: due_at)
      occurrence.fail!(at: attempted_at)
    end
  end
end
