require "rails_helper"

RSpec.describe "backup plugin capabilities" do
  it "enforces the artifact-source contract for external registrations" do
    expect {
      Syrus::PluginRegistry.register(name: "external_backup", version: "1.0.0", provides: { backup_artifact_source: Class.new })
    }.to raise_error(Syrus::PluginRegistry::RegistrationError, /BackupArtifactSource/)
  end

  it "accepts destination implementations and exposes the v1 compatibility version" do
    provider = Class.new { include Syrus::Plugin::BackupDestination }
    Syrus::PluginRegistry.register(name: "external_destination", version: "1.0.0", provides: { backup_destination: provider })

    expect(Syrus::PluginRegistry.providers_for(:backup_destination)).to include(provider)
    expect(provider.contract_version).to eq(1)
    expect(provider.compatible_contract?(1)).to be(true)
    expect(provider.compatible_contract?(2)).to be(false)
  ensure
    Syrus::PluginRegistry.restore(Syrus::PluginRegistry.boot_snapshot)
  end
end
