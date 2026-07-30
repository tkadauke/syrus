module SyrusCodexAgent
  class Engine < ::Rails::Engine
    # after_initialize runs after Zeitwerk is fully active, ensuring
    # Syrus::PluginRegistry (autoloaded from lib/) is resolvable.
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:    "syrus-codex-agent",
        version: SyrusCodexAgent::VERSION,
        provides: { agent_provider: AgentProviders::Codex }
      )
    end
  end
end
