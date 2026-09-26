module Filters
  module Chips
    module AgentInsights
      class TargetInsightId < FkColumn
        filter_name "target_insight_id"
        label "Target insight ID"
        column :target_insight_id
      end
    end
  end
end
