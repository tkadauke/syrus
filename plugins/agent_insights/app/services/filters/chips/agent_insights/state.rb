module Filters
  module Chips
    module AgentInsights
      class State < Syrus::Host::Filters::Chips::EnumColumn
        filter_name "state"
        label "State"
        column :state
        values "pending", "accepted", "dismissed", "retired"
      end
    end
  end
end
