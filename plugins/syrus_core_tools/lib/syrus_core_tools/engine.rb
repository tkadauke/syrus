module SyrusCoreTools
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name: "syrus_core_tools",
        version: SyrusCoreTools::VERSION,
        provides: { mcp_tool_set: SyrusMcp::CoreToolSet }
      )
    end
  end
end
