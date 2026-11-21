module ScheduledTasks
  module FilterExtension
    def self.install_into(scope)
      scope.effect("scheduled task Job filter") do
        ::Filters.register_chips(subject: :job, chips: {
          "scheduled_task_id" => "ScheduledTasks::Filters::ScheduledTaskId"
        })
      end
    end
  end
end
