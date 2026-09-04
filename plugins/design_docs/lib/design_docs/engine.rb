module DesignDocs
  class Engine < ::Rails::Engine
    config.to_prepare do
      DesignDocs::DataCleanup.install!
    end

    config.to_prepare do
      DesignDocs::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet) unless DesignDocs::ChatToolSet < Syrus::Plugin::ChatMcpToolSet
      DesignDocs::WorkflowToolSet.include(Syrus::Plugin::McpToolSet) unless DesignDocs::WorkflowToolSet < Syrus::Plugin::McpToolSet

      DesignDocs.register!
    end
  end
end
