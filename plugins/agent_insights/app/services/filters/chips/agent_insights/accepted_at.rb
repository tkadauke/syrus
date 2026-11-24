module Filters
  module Chips
    module AgentInsights
      class AcceptedAt < Syrus::Host::Filters::Chips::DateColumn
        filter_name "accepted_at"
        label "Accepted at"
        column :accepted_at
      end
    end
  end
end
