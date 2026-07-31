# Re-register bundled plugins before each example so registry-backed model
# validations and settings payloads work correctly in tests.
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

    registered_names = Syrus::PluginRegistry.registered_names

    unless registered_names.include?("syrus-claude-agent")
      Syrus::PluginRegistry.register(
        name:    "syrus-claude-agent",
        version: SyrusClaudeAgent::VERSION,
        provides: { agent_provider: AgentProviders::Claude }
      )
    end

    unless registered_names.include?("syrus-codex-agent")
      Syrus::PluginRegistry.register(
        name:    "syrus-codex-agent",
        version: SyrusCodexAgent::VERSION,
        provides: { agent_provider: AgentProviders::Codex }
      )
    end

    unless registered_names.include?("syrus_core_tools")
      Syrus::PluginRegistry.register(
        name: "syrus_core_tools",
        version: SyrusCoreTools::VERSION,
        provides: { mcp_tool_set: SyrusMcp::CoreToolSet }
      )
    end

    unless registered_names.include?("syrus-github-source")
      Syrus::PluginRegistry.register(
        name: "syrus-github-source",
        version: SyrusGithubSource::VERSION,
        provides: { input_source: InputSources::Github }
      )
    end

    unless registered_names.include?("syrus-linear-source")
      Syrus::PluginRegistry.register(
        name: "syrus-linear-source",
        version: SyrusLinearSource::VERSION,
        provides: { input_source: InputSources::Linear }
      )
    end
  end
end
