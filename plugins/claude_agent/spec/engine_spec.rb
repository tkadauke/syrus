require "rails_helper"

RSpec.describe SyrusClaudeAgent::Engine do
  # The after_initialize block already ran during Rails boot and was then
  # reset by config/initializers/plugin_registry.rb in test mode.
  # The bundled_plugins support file re-registers before each example;
  # we only need to verify the result is observable here.

  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "registers Claude providers via after_initialize" do
    # bundled_plugins.rb ensures the registry is populated before this runs
    expect(Syrus::PluginRegistry.providers_for(:agent_provider)).to include(AgentProviders::Claude)
    expect(Syrus::PluginRegistry.providers_for(:chat_provider)).to include(ChatProviders::Claude)
    expect(ChatSessionRehydrator.for("claude")).to eq(ChatSessionRehydrator::Claude)
  end

  it "registers a manifest named 'claude_agent'" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "claude_agent" }
    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(Syrus::PluginApi.default_version)
  end
end
