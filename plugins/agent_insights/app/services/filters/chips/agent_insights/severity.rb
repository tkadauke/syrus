module Filters
  module Chips
    module AgentInsights
      class Severity < EnumColumn
        filter_name "severity"
        label "Severity"
        column :severity
        values ::AgentInsights::Suggestion::SEVERITIES
      end
    end
  end
end
