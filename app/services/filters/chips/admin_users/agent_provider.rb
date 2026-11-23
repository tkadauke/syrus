module Filters
  module Chips
    module AdminUsers
      class AgentProvider < EnumColumn
        filter_name "agent_provider"
        label "Agent provider"
        column :agent_provider

        def self.values
          Syrus::Plugin::ServiceProvider.providers(:agent_provider).map(&:provider_key).sort
        end
      end
    end
  end
end
