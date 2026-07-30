require "rails_helper"

RSpec.describe SyrusClaudeAgent::Engine do
  # The after_initialize block already ran during Rails boot and was then
  # reset by config/initializers/plugin_registry.rb in test mode.
  # The bundled_plugins support file re-registers before each example;
  # we only need to verify the result is observable here.

  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "registers AgentProviders::Claude via after_initialize" do
    # bundled_plugins.rb ensures the registry is populated before this runs
    providers = Syrus::PluginRegistry.providers_for(:agent_provider)
    expect(providers).to include(AgentProviders::Claude)
  end

  it "registers a manifest named 'syrus-claude-agent'" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "syrus-claude-agent" }
    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(SyrusClaudeAgent::VERSION)
  end
end
