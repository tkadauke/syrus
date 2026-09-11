module Filters
  module Chips
    module AgentInsights
      class State < EnumColumn
        filter_name "state"
        label "State"
        column :state
        values ::AgentInsights::Suggestion::STATES
      end
    end
  end
end
