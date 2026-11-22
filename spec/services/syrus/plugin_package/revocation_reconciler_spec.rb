require "rails_helper"

RSpec.describe Syrus::PluginPackage::RevocationReconciler do
  before { allow(PluginDesiredState::Publisher).to receive(:publish!) }

  def installed_release(name: "weather", version: "1.2.3", fingerprint: "a" * 64, plugin_registry: nil)
    body = "plugin archive"
    digest = Digest::SHA256.hexdigest(body)
    release = PluginRelease.create!(name:, version:, content_digest: digest,
      source: "registry", trust_label: "verified", publisher_key_fingerprint: fingerprint, size_bytes: body.bytesize,
      plugin_registry:)
    release.archive.attach(io: StringIO.new(body), filename: "#{name}.archive")
    PluginInstallation.create!(plugin_name: name, plugin_release: release)
  end

  it "fleet-quarantines an installed plugin when its publisher key is later revoked" do
    installation = installed_release
    store = Syrus::PluginPackage::TrustStore.new("publishers" => [], "revoked_keys" => [ "a" * 64 ])

    expect(described_class.new(store).call).to eq([ installation ])
    expect(installation.reload).to be_fleet_quarantined
  end

  it "fleet-quarantines a specifically revoked release" do
    installation = installed_release
    store = Syrus::PluginPackage::TrustStore.new("publishers" => [], "revoked_releases" => [
      { "name" => "weather", "version" => "1.2.3", "digest" => installation.plugin_release.content_digest }
    ])

    described_class.new(store).call
    expect(installation.reload).to be_fleet_quarantined
  end

  it "quarantines every revoked installation before publishing desired state" do
    first = installed_release(name: "first")
    second = installed_release(name: "second")
    store = Syrus::PluginPackage::TrustStore.new("revoked_keys" => [ "a" * 64 ])
    allow(PluginDesiredState::Publisher).to receive(:publish!).and_raise("storage unavailable")

    expect { described_class.new(store).call }.to raise_error("storage unavailable")

    expect(first.reload).to be_fleet_quarantined
    expect(second.reload).to be_fleet_quarantined
  end

  it "retries desired-state publication after quarantining was already persisted" do
    installation = installed_release
    store = Syrus::PluginPackage::TrustStore.new("revoked_keys" => [ "a" * 64 ])
    attempts = 0
    allow(PluginDesiredState::Publisher).to receive(:publish!) do
      attempts += 1
      raise "storage unavailable" if attempts == 1
    end

    expect { described_class.new(store).call }.to raise_error("storage unavailable")
    expect { described_class.new(store).call }.not_to raise_error

    expect(installation.reload).to be_fleet_quarantined
    expect(attempts).to eq(2)
  end

  it "applies revocations only to installations from the matching registry" do
    allow(SsrfGuard).to receive(:safe_host?).and_return(true)
    source = PluginRegistry.create!(name: "source", url: "https://source.example.test")
    other = PluginRegistry.create!(name: "other", url: "https://other.example.test")
    matching = installed_release(name: "source_weather", plugin_registry: source)
    isolated = installed_release(name: "other_weather", plugin_registry: other)
    store = Syrus::PluginPackage::TrustStore.new("revoked_keys" => [ "a" * 64 ])

    expect(described_class.new(store, plugin_registry: source).call).to eq([ matching ])
    expect(matching.reload).to be_fleet_quarantined
    expect(isolated.reload).not_to be_fleet_quarantined
  end
end
