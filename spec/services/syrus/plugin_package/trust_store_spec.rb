require "rails_helper"

RSpec.describe Syrus::PluginPackage::TrustStore do
  before { allow(PluginDesiredState::Publisher).to receive(:publish!) }

  it "preserves publisher prefixes when caching registry trust" do
    store = described_class.new("publishers" => [ {
      "fingerprint" => "a" * 64, "label" => "verified", "prefix" => "acme"
    } ])

    expect(store.publisher("a" * 64).prefix).to eq("acme")
    expect(store.as_json.fetch("publishers").first).to include("prefix" => "acme")
  end

  it "caches the registry trust store and immediately quarantines newly revoked installations" do
    body = "plugin archive"
    fingerprint = "a" * 64
    release = PluginRelease.create!(
      name: "weather", version: "1.2.3", content_digest: Digest::SHA256.hexdigest(body),
      source: "registry", trust_label: "verified", publisher_key_fingerprint: fingerprint,
      signature: "detached signature", size_bytes: body.bytesize
    )
    release.archive.attach(io: StringIO.new(body), filename: "weather.archive")
    installation = PluginInstallation.create!(plugin_name: "weather", plugin_release: release)
    path = Pathname.new(Dir.mktmpdir).join("registry", "trust-store.json")
    allow(described_class).to receive(:cache_path).and_return(path)

    described_class.cache!({ "revoked_keys" => [ fingerprint ] })

    expect(described_class.cached.revoked_keys).to include(fingerprint)
    expect(installation.reload).to be_fleet_quarantined
  ensure
    FileUtils.rm_rf(path&.dirname&.dirname)
  end

  it "retries a failed quarantine publication when the cached store is next read" do
    body = "plugin archive"
    fingerprint = "a" * 64
    release = PluginRelease.create!(
      name: "weather", version: "1.2.3", content_digest: Digest::SHA256.hexdigest(body),
      source: "registry", trust_label: "verified", publisher_key_fingerprint: fingerprint,
      signature: "detached signature", size_bytes: body.bytesize
    )
    release.archive.attach(io: StringIO.new(body), filename: "weather.archive")
    installation = PluginInstallation.create!(plugin_name: "weather", plugin_release: release)
    path = Pathname.new(Dir.mktmpdir).join("registry", "trust-store.json")
    attempts = 0
    allow(PluginDesiredState::Publisher).to receive(:publish!) do
      attempts += 1
      raise "storage unavailable" if attempts == 1
    end

    expect { described_class.cache!({ "revoked_keys" => [ fingerprint ] }, path:) }
      .to raise_error("storage unavailable")
    expect(path).not_to exist
    expect(described_class.reconciliation_path(path)).to exist
    expect(installation.reload).to be_fleet_quarantined

    expect(described_class.cached(path:).revoked_keys).to include(fingerprint)
    expect(path).to exist
    expect(described_class.reconciliation_path(path)).not_to exist
    expect(attempts).to eq(2)
  ensure
    FileUtils.rm_rf(path&.dirname&.dirname)
  end
end
