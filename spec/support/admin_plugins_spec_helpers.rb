module AdminPluginsSpec
  class AvailableProvider
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "available"
    def self.display_name = "Available"
    def self.available? = true
  end

  class UnavailableProvider
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "unavailable"
    def self.display_name = "Unavailable"
    def self.available? = false
  end

  class CustomInputSource < InputSource
    include Syrus::Plugin::InputSource
  end

  # Stubs for the two provider keys the factories rely on. User#agent_provider
  # and Job#agent_provider validate against User.agent_providers, which reads
  # the registry - so a spec that genuinely empties the registry (via
  # :reset_plugin_registry) has to put these back before it can build records.
  class ClaudeStubProvider
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "claude"
    def self.display_name = "Claude"
    def self.available? = true
  end

  class CodexStubProvider
    include Syrus::Plugin::AgentProvider

    def self.provider_key = "codex"
    def self.display_name = "Codex"
    def self.available? = true
  end

  def self.register_factory_agent_providers!
    Syrus::PluginRegistry.register(
      name: "claude_agent_stub", version: "1.0.0",
      provides: { agent_provider: ClaudeStubProvider }
    )
    Syrus::PluginRegistry.register(
      name: "codex_agent_stub", version: "1.0.0",
      provides: { agent_provider: CodexStubProvider }
    )
  end
end
