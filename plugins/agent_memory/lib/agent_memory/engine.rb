module AgentMemory
  class Engine < ::Rails::Engine
    config.to_prepare do
      AgentMemory::DataCleanup.install!
    end

    config.after_initialize do
      unless AgentMemory::McpToolSet < Syrus::Plugin::McpToolSet
        AgentMemory::McpToolSet.include(Syrus::Plugin::McpToolSet)
      end
      unless AgentMemory::ChatToolSet < Syrus::Plugin::ChatMcpToolSet
        AgentMemory::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet)
      end

      AgentMemory.register!
    end
  end
end
