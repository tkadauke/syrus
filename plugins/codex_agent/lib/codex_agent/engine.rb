module SyrusCodexAgent
  class Engine < ::Rails::Engine
    # after_initialize runs after Zeitwerk is fully active, ensuring
    # Syrus::PluginRegistry (autoloaded from lib/) is resolvable.
    config.after_initialize do
      # No icon_url: no OpenAI/Codex mark is currently published through
      # Simple Icons (simpleicons.org) under a CC0-style license, so this
      # falls back to the SPQR eagle like any other plugin without a
      # sourced brand mark (see config/syrus_docs/plugins.md).
      Syrus::PluginRegistry.register(
        name:            "codex_agent",
        display_name:    "Codex Agent",
        version:         SyrusCodexAgent::VERSION,
        description:     "Runs workflow and chat turns through Codex.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "agent",
        provides: {
          agent_provider: AgentProviders::Codex,
          chat_provider:  ChatProviders::Codex
        }
      )
    end
  end
end
