module Filters
  module Chips
    module AgentInsights
      class SupersededByInsightId < FkColumn
        filter_name "superseded_by_insight_id"
        label "Superseded by insight ID"
        column :superseded_by_insight_id
      end
    end
  end
end
