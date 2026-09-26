module Filters
  module Chips
    module AdminUsers
      class SchedulingPaused < Base
        filter_name "scheduling_paused"
        label "Scheduling paused"
        bucket :enum
        operators :is
        values({ value: "true", label: "Paused" }, { value: "false", label: "Active" })

        def apply
          scope.where(scheduling_paused: ActiveModel::Type::Boolean.new.cast(value))
        end
      end
    end
  end
end
