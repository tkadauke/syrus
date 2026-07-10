# Re-register bundled agent provider plugins before each example so that
# User.agent_providers and model validations work correctly in tests.
#
# config/initializers/plugin_registry.rb resets the registry via
# after_initialize in test mode. This before hook restores the bundled
# providers before each example.
#
# Examples tagged :reset_plugin_registry (i.e. plugin_registry_spec) opt out
# so their around block gets a genuinely empty registry. RSpec hook ordering is
# around-pre → before → example, so the before hook would otherwise fire after
# the around reset and repopulate the registry before the example body runs.
RSpec.configure do |config|
  config.before do |example|
    next if example.metadata[:reset_plugin_registry]

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
