module Filters
  module Chips
    module AgentInsights
      class TargetMemoryId < Syrus::Host::Filters::Chips::NumberColumn
        filter_name "target_memory_id"
        label "Target memory ID"
        column :target_memory_id
      end
    end
  end
end
