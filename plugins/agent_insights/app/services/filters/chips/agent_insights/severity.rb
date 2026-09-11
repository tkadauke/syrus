module Filters
  module Chips
    module AgentInsights
      class Severity < EnumColumn
        filter_name "severity"
        label "Severity"
        column :severity
        values "high", "medium", "low"
      end
    end
  end
end
