module Filters
  module Chips
    module Workflows
      class State < EnumColumn
        filter_name "state"
        label "State"
        column :state
        values "queued", "running", "succeeded", "failed", "cancelled"
      end
    end
  end
end
