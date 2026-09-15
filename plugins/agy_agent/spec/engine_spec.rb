require "rails_helper"

RSpec.describe SyrusAgyAgent::Engine do
  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "registers the Agy provider via after_initialize" do
    expect(Syrus::PluginRegistry.providers_for(:agent_provider)).to include(AgentProviders::Agy)
  end

  it "registers the Agy chat provider via after_initialize" do
    expect(Syrus::PluginRegistry.providers_for(:chat_provider)).to include(ChatProviders::Agy)
  end

  it "registers a manifest named 'agy_agent'" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "agy_agent" }
    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(Syrus::PluginApi.default_version)
    expect(manifest.category).to eq("agent_provider")
  end
end
