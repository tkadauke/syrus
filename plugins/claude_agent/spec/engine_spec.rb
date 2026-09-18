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

  it "defaults to disabled so new installs opt in during onboarding" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "claude_agent" }
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.disableable?).to be(true)
  end

  it "creates a disabled PluginRecord for a brand-new install" do
    PluginRecord.where(name: "claude_agent").delete_all

    SyrusClaudeAgent.register!

    expect(PluginRecord.find_by!(name: "claude_agent").enabled).to be(false)
  ensure
    PluginRecord.find_or_create_by!(name: "claude_agent").update!(enabled: true)
  end

  it "leaves an already-enabled PluginRecord enabled across re-registration" do
    record = PluginRecord.find_or_create_by!(name: "claude_agent")
    record.update!(enabled: true)

    SyrusClaudeAgent.register!

    expect(PluginRecord.find_by!(name: "claude_agent").enabled).to be(true)
  end
end
