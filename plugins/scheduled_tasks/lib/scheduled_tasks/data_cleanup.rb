module ScheduledTasks
  # What used to be `Repository has_many :scheduled_tasks, dependent: :destroy`
  # and `User has_many :cron_templates`, declared on the core models.
  #
  # Installed with `always`, not `while_enabled`: disabling this plugin stops
  # schedules firing, it does not delete the schedules an operator configured,
  # and those still have to go when their repository or user does.
  module DataCleanup
    def self.install_into(scope)
      scope.effect("repository schedules") do
        Syrus::DataCleanup.register("Repository", "scheduled_tasks.tasks") do |repository|
          ScheduledTasks::Task.where(repository_id: repository.id).find_each(&:destroy)
        end
      end

      scope.effect("user cron templates") do
        Syrus::DataCleanup.register("User", "scheduled_tasks.cron_templates") do |user|
          ScheduledTasks::CronTemplate.where(user_id: user.id).find_each(&:destroy)
        end
      end
    end
  end
end
