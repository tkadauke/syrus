module Filters
  module Chips
    module Jobs
      class AgentProvider < EnumColumn
        filter_name "agent_provider"
        label "Agent"
        column :agent_provider
        values "claude", "codex"
      end
    end
  end
end
