module Filters
  module Chips
    module AgentInsights
      class TargetInsightId < Syrus::Host::Filters::Chips::FkColumn
        filter_name "target_insight_id"
        label "Target insight ID"
        column :target_insight_id
      end
    end
  end
end
