module SyrusClaudeAgent
  class Engine < ::Rails::Engine
    # after_initialize runs after Zeitwerk is fully active, ensuring
    # Syrus::PluginRegistry (autoloaded from lib/) is resolvable.
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "claude_agent",
        display_name:    "Claude Agent",
        version:         SyrusClaudeAgent::VERSION,
        description:     "Runs workflow and chat turns through Claude.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "agent_provider",
        provides: {
          agent_provider: AgentProviders::Claude,
          chat_provider:  ChatProviders::Claude
        }
      )
    end
  end
end
