require "rails_helper"

RSpec.describe PluginInstallation do
  let(:release) do
    PluginRelease.create!(name: "weather", version: "1.0.0", content_digest: "a" * 64,
      source: "bundled", trust_label: "official", size_bytes: 0)
  end

  it "publishes after desired state is created, changed, and removed" do
    allow(PluginDesiredState::Publisher).to receive(:publish!)

    installation = described_class.create!(plugin_name: "weather", plugin_release: release)
    installation.update!(fleet_quarantined: true)
    installation.destroy!

    expect(PluginDesiredState::Publisher).to have_received(:publish!).exactly(3).times
  end

  it "requires the installation identity to match its release" do
    installation = described_class.new(plugin_name: "different", plugin_release: release)

    expect(installation).not_to be_valid
    expect(installation.errors[:plugin_name]).to include("must match the release name")
  end

  it "publishes when the selected release metadata changes" do
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    described_class.create!(plugin_name: "weather", plugin_release: release)
    expect(PluginDesiredState::Publisher).to receive(:publish!).once

    release.update!(trust_label: "verified")
  end

  it "does not enable an uploaded release before its artifact is verified" do
    uploaded = PluginRelease.create!(name: "uploaded", version: "1.0.0", content_digest: "b" * 64,
      source: "upload", trust_label: "unsigned_local", size_bytes: 12)

    installation = described_class.new(plugin_name: "uploaded", plugin_release: uploaded)

    expect(installation).not_to be_valid
    expect(installation.errors[:plugin_release]).to include("must have a verified artifact")
  end

  it "refuses to select a release revoked by the cached trust store" do
    release.update!(publisher_key_fingerprint: "a" * 64)
    trust_store = Syrus::PluginPackage::TrustStore.new("revoked_keys" => [ "a" * 64 ])
    allow(Syrus::PluginPackage::TrustStore).to receive(:cached).and_return(trust_store)

    installation = described_class.new(plugin_name: "weather", plugin_release: release)

    expect(installation).not_to be_valid
    expect(installation.errors[:plugin_release]).to include("has been revoked")
  end

  it "accepts only supported process roles, with an empty list meaning all roles" do
    expect(described_class.new(plugin_name: "weather", plugin_release: release, roles: [])).to be_valid
    expect(described_class.new(plugin_name: "weather", plugin_release: release, roles: %w[web sidecar])).to be_valid

    installation = described_class.new(plugin_name: "weather", plugin_release: release, roles: %w[database])
    expect(installation).not_to be_valid
    expect(installation.errors[:roles].join).to include("database")
  end
end
