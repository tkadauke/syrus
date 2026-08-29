module DesignDocs
  class Engine < ::Rails::Engine
    config.after_initialize do
      DesignDocs::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet) unless DesignDocs::ChatToolSet < Syrus::Plugin::ChatMcpToolSet
      DesignDocs::WorkflowToolSet.include(Syrus::Plugin::McpToolSet) unless DesignDocs::WorkflowToolSet < Syrus::Plugin::McpToolSet
      DesignDocs::PromptContext.include(Syrus::Plugin::PromptInjector) unless DesignDocs::PromptContext < Syrus::Plugin::PromptInjector

      DesignDocs.register!
    end
  end
end
