module Filters
  module Chips
    module AgentInsights
      class Confidence < NumberColumn
        filter_name "confidence"
        label "Confidence"
        column :confidence
      end
    end
  end
end
