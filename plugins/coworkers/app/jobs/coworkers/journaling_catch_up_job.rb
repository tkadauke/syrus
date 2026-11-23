module Coworkers
  class JournalingCatchUpJob < Syrus::Host::PluginJob
    plugin :coworkers
    retry_on Syrus::Host::WorkLauncher::LockConflict, wait: 30.seconds, attempts: 10 do |job, error|
      job.record_discarded_failure(error)
    end

    def perform(task_id, after_date, remaining)
      task = ScheduledTasks::Task.alive.find_by(id: task_id, system_key: Coworkers::SystemSchedules::JOURNALING)
      return unless task&.active?

      Coworkers::ScheduledTaskFireHandler.new(task).fire_journaling_catch_up!(
        after_date: Date.iso8601(after_date), remaining: Integer(remaining)
      )
    end
  end
end
