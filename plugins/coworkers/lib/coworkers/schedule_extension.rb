module Coworkers
  module ScheduleExtension
    def self.install_into(scope)
      ScheduledTasks::SystemSchedules.register("journaling", definition: Coworkers::Prompts::Journaling)
      scope.effect("coworker scheduled task fire handler") do
        ScheduledTasks::FireHandlers.register(
          target: :coworker,
          handler: Coworkers::ScheduledTaskFireHandler
        ) { |task| task.respond_to?(:coworker_id) && task.coworker_id.present? }
      end
    end
  end
end
