module Filters
  module Chips
    module AgentInsights
      class DismissedAt < DateColumn
        filter_name "dismissed_at"
        label "Dismissed at"
        column :dismissed_at
      end
    end
  end
end
