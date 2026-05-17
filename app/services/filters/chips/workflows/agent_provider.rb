module Filters
  module Chips
    module Workflows
      class AgentProvider < EnumColumn
        filter_name "agent_provider"
        label "Agent"
        column :agent_provider
        values(*AgentProviders::REGISTRY.keys)
      end
    end
  end
end
