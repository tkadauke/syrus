module Filters
  module Chips
    module AgentInsights
      class Confidence < Syrus::Host::Filters::Chips::NumberColumn
        filter_name "confidence"
        label "Confidence"
        column :confidence
      end
    end
  end
end
