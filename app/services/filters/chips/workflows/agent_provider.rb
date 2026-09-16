module Filters
  module Chips
    module Workflows
      class AgentProvider < EnumColumn
        filter_name "agent_provider"
        label "Agent"
        column :agent_provider

        def self.values
          User.agent_providers.map { |key| key == "agy" ? { "value" => key, "label" => "Antigravity" } : key }
        end
      end
    end
  end
end
