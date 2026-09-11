module Filters
  module Chips
    module AgentInsights
      class State < EnumColumn
        filter_name "state"
        label "State"
        column :state
        values "pending", "accepted", "dismissed", "retired"
      end
    end
  end
end
