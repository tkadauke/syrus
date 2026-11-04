module Coworkers
  class JournalingCatchUpJob < ApplicationJob
    queue_as :control_plane
    retry_on WorkUnits::Launcher::LockConflict, wait: 30.seconds, attempts: 10

    def perform(task_id, after_date, remaining)
      task = ScheduledTasks::Task.alive.find_by(id: task_id, system_key: Coworkers::SystemSchedules::JOURNALING)
      return unless task&.active?

      Coworkers::ScheduledTaskFireHandler.new(task).fire_journaling_catch_up!(
        after_date: Date.iso8601(after_date), remaining: Integer(remaining)
      )
    end
  end
end
