require "rails_helper"

RSpec.describe SyrusMuseAgent::Engine do
  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "registers a manifest named 'muse_agent' without provider execution" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "muse_agent" }

    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(Syrus::PluginApi.default_version)
    expect(Syrus::PluginRegistry.providers_for(:agent_provider).map(&:provider_key)).not_to include("muse")
    expect(Syrus::PluginRegistry.providers_for(:chat_provider).map(&:provider_key)).not_to include("muse")
  end

  it "registers Muse credential probe effects only while enabled" do
    record = PluginRecord.find_by!(name: "muse_agent")
    record.update!(enabled: true)
    expect(CredentialProbe.probe_handler_for("muse_api_key")).to eq(MuseCredentialProbe)

    record.update!(enabled: false)
    expect(CredentialProbe.probe_handler_for("muse_api_key")).to be_nil
  ensure
    record&.update!(enabled: true)
  end
end
