module Filters
  module Chips
    module SpendingReport
      class AgentProvider < EnumColumn
        filter_name "agent_provider"
        label "Agent"
        column :agent_provider

        def self.values
          Syrus::Host::UserRecord.agent_providers
        end
      end
    end
  end
end
