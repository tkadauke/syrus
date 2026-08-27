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
        long_description: "Codex Agent connects Syrus workflows and chats to Codex. It provides the provider adapter used for implementation, review, repair, coding handoff, and interactive chat sessions, while feeding provider availability and failure classification back into Syrus' admission and retry systems.\n\nEnable this plugin when a Syrus instance should offer Codex-backed automation. It is independent from the Claude plugin, so operators can run either provider or both.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/codex_agent.svg",
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
