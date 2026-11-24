module Filters
  module Chips
    module AgentInsights
      class Severity < Syrus::Host::Filters::Chips::EnumColumn
        filter_name "severity"
        label "Severity"
        column :severity
        values "high", "medium", "low"
      end
    end
  end
end
