require "rails_helper"

RSpec.describe Syrus::PluginPackage::TrustStore do
  it "caches the registry trust store and immediately quarantines newly revoked installations" do
    body = "plugin archive"
    fingerprint = "a" * 64
    release = PluginRelease.create!(
      name: "weather", version: "1.2.3", content_digest: Digest::SHA256.hexdigest(body),
      source: "registry", trust_label: "verified", publisher_key_fingerprint: fingerprint,
      signature: "detached signature", size_bytes: body.bytesize
    )
    allow(PluginDesiredState::Publisher).to receive(:publish!)
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
end
