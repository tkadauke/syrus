module Filters
  module Chips
    module AgentInsights
      class RetiredAt < Syrus::Host::Filters::Chips::DateColumn
        filter_name "retired_at"
        label "Retired at"
        column :retired_at
      end
    end
  end
end
