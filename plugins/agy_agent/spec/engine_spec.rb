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

  it "registers the Antigravity CredentialProbe" do
    expect(CredentialProbe.probe_handler_for("agy")).to eq(AgyCredentialProbe)
  end

  it "registers a manifest named 'agy_agent'" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "agy_agent" }
    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(Syrus::PluginApi.default_version)
    expect(manifest.category).to eq("agent_provider")
  end

  it "defaults to disabled so new installs opt in during onboarding" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "agy_agent" }
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.disableable?).to be(true)
  end

  it "creates a disabled PluginRecord for a brand-new install" do
    PluginRecord.where(name: "agy_agent").delete_all

    SyrusAgyAgent.register!

    expect(PluginRecord.find_by!(name: "agy_agent").enabled).to be(false)
  ensure
    PluginRecord.find_or_create_by!(name: "agy_agent").update!(enabled: true)
  end

  it "leaves an already-enabled PluginRecord enabled across re-registration" do
    record = PluginRecord.find_or_create_by!(name: "agy_agent")
    record.update!(enabled: true)

    SyrusAgyAgent.register!

    expect(PluginRecord.find_by!(name: "agy_agent").enabled).to be(true)
  end
end
