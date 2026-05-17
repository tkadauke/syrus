module Filters
  module Chips
    module Jobs
      class Priority < EnumColumn
        filter_name "priority"
        label "Priority"
        column :priority
        values "high", "medium", "low"
      end
    end
  end
end
