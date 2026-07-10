# Re-register bundled agent provider plugins before each example so that
# User.agent_providers and model validations work correctly in tests.
#
# config/initializers/plugin_registry.rb resets the registry via
# after_initialize in test mode (giving the plugin_registry_spec clean
# isolation). This before hook restores the bundled providers before each
# example. The plugin_registry_spec's own around block resets the registry
# before ex.run, so examples that need a clean registry still get one.
RSpec.configure do |config|
  config.before do
    unless Syrus::PluginRegistry.providers_for(:agent_provider).any?
      Syrus::PluginRegistry.register(
        name:    "syrus-claude-agent",
        version: SyrusClaudeAgent::VERSION,
        provides: { agent_provider: AgentProviders::Claude }
      )
      Syrus::PluginRegistry.register(
        name:    "syrus-codex-agent",
        version: SyrusCodexAgent::VERSION,
        provides: { agent_provider: AgentProviders::Codex }
      )
    end
  end
end
