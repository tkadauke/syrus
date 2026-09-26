module Filters
  module Chips
    module AgentInsights
      class RetiredAt < DateColumn
        filter_name "retired_at"
        label "Retired at"
        column :retired_at
      end
    end
  end
end
