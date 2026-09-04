module AgentInsights
  class Engine < ::Rails::Engine
    config.to_prepare do
      AgentInsights::DataCleanup.install!
    end

    config.to_prepare do
      unless AgentInsights::McpToolSet < Syrus::Plugin::McpToolSet
        AgentInsights::McpToolSet.include(Syrus::Plugin::McpToolSet)
      end
      unless AgentInsights::ChatToolSet < Syrus::Plugin::ChatMcpToolSet
        AgentInsights::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet)
      end

      AgentInsights.register!
    end
  end
end
