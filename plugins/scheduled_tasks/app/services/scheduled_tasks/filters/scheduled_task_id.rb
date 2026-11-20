module ScheduledTasks
  module Filters
    class ScheduledTaskId < ::Filters::Chips::EnumColumn
      filter_name "scheduled_task_id"
      label "Schedule"
      column :scheduled_task_id

      def self.schema_values(user)
        scope = user.admin? ? Task.alive : Task.alive.where(user: user)
        scope.order(Arel.sql("LOWER(name)"), :id).map do |task|
          { "value" => task.id.to_s, "label" => task.name }
        end
      end
    end
  end
end
