require "rails_helper"

RSpec.describe SyrusMuseAgent::Engine do
  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "registers a manifest named 'muse_agent' with workflow and chat provider execution" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == "muse_agent" }

    expect(manifest).not_to be_nil
    expect(manifest.version).to eq(Syrus::PluginApi.default_version)
    expect(manifest.default_enabled?).to be false
    expect(manifest.disableable?).to be true
  end

  it "withholds Muse providers until the rollout plugin is enabled" do
    record = PluginRecord.find_or_create_by!(name: "muse_agent")
    record.update!(enabled: false, default_enabled: false, disableable: true)

    expect(Syrus::PluginRegistry.providers_for(:agent_provider).map(&:provider_key)).not_to include("muse")
    expect(Syrus::PluginRegistry.providers_for(:chat_provider).map(&:provider_key)).not_to include("muse")

    record.update!(enabled: true)

    expect(Syrus::PluginRegistry.providers_for(:agent_provider).map(&:provider_key)).to include("muse")
    expect(Syrus::PluginRegistry.providers_for(:chat_provider).map(&:provider_key)).to include("muse")
  ensure
    record&.update!(enabled: false, default_enabled: false, disableable: true)
  end

  it "keeps Muse credential probes available while provider execution is disabled" do
    record = PluginRecord.find_or_create_by!(name: "muse_agent") do |plugin|
      plugin.enabled = true
      plugin.default_enabled = false
      plugin.disableable = true
    end
    record.update!(enabled: true, default_enabled: false)
    expect(CredentialProbe.probe_handler_for("muse_api_key")).to eq(MuseCredentialProbe)
    expect(ChatSessionRehydrator.for("muse")).to eq(ChatSessionRehydrator::Muse)

    record.update!(enabled: false)
    expect(CredentialProbe.probe_handler_for("muse_api_key")).to eq(MuseCredentialProbe)
    expect(ChatSessionRehydrator.for("muse")).to be_nil
  ensure
    record&.update!(enabled: false, default_enabled: false, disableable: true)
  end
end
