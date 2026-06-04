# Opencode isn't split into its own plugin gem (unlike claude_agent /
# codex_agent) — it has no external dependency beyond the `opencode` CLI and
# a local Ollama instance, so it registers directly from the core app.
#
# after_initialize so Zeitwerk is fully active before Syrus::PluginRegistry
# and AgentProviders::Opencode are resolved (matches the plugin engines'
# registration timing).
Rails.application.config.after_initialize do
  Syrus::PluginRegistry.register(
    name:            "opencode_agent",
    display_name:    "OpenCode Agent",
    version:         "0.1.0",
    description:     "Runs workflow and chat turns through OpenCode against a local Ollama model.",
    default_enabled: true,
    disableable:     true,
    category:        "agent_provider",
    provides: {
      agent_provider: AgentProviders::Opencode
    }
  )
end
