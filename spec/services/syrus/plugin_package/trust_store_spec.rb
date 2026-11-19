require "rails_helper"

RSpec.describe Syrus::PluginPackage::TrustStore do
  let(:key) { OpenSSL::PKey.generate_key("ED25519") }
  let(:other_key) { OpenSSL::PKey.generate_key("ED25519") }
  let(:package) { Tempfile.new.tap { |file| file.binmode; file.write("package"); file.close } }
  let(:fingerprint) { described_class.fingerprint(key) }

  def signature(signing_key = key)
    digest = Digest::SHA256.file(package.path).digest
    StringIO.new(JSON.generate(version: 1, algorithm: "ed25519", fingerprint: described_class.fingerprint(signing_key),
      digest: "sha256:#{digest.unpack1("H*")}", signature: Base64.strict_encode64(signing_key.sign(nil, digest))))
  end

  def store(label: "verified", revoked_keys: [], revoked_releases: [])
    described_class.new(version: 1, keys: [ { fingerprint:, label:, public_key: Base64.strict_encode64(key.public_to_der) } ],
      revoked_keys:, revoked_releases:)
  end

  %w[official verified community].each do |label|
    it "returns the #{label} trust label" do
      expect(store(label:).verify(package: package.path, signature: signature, name: "weather", version: "1.0"))
        .to have_attributes(trusted?: true, label:)
    end
  end

  it "labels an unsigned local package without treating it as verified" do
    expect(store.unsigned_local).to have_attributes(trusted?: false, label: "unsigned_local", reason: "unsigned_local")
  end

  it "rejects tampering and the wrong key" do
    signed = signature
    File.binwrite(package.path, "tampered")
    expect(store.verify(package: package.path, signature: signed, name: "weather", version: "1.0").reason).to eq("invalid_signature")
    expect(store.verify(package: package.path, signature: signature(other_key), name: "weather", version: "1.0").reason).to eq("unknown_key")
  end

  it "refuses revoked keys and releases" do
    expect(store(revoked_keys: [ fingerprint ]).verify(package: package.path, signature: signature, name: "weather", version: "1.0").reason).to eq("revoked_key")
    release = { name: "weather", version: "1.0", digest: Digest::SHA256.file(package.path).hexdigest }
    expect(store(revoked_releases: [ release ]).verify(package: package.path, signature: signature, name: "weather", version: "1.0").reason).to eq("revoked_release")
  end

  it "flags a previously installed release when its publisher is later revoked" do
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    release = PluginRelease.create!(name: "weather", version: "1.0", content_digest: Digest::SHA256.file(package.path).hexdigest,
      source: "bundled", trust_label: "verified", publisher_fingerprint: fingerprint, size_bytes: 0)
    installation = PluginInstallation.create!(plugin_name: "weather", plugin_release: release)

    count = store(revoked_keys: [ fingerprint ]).quarantine_revoked_installations!

    expect(count).to eq(1)
    expect(installation.reload).to be_fleet_quarantined
    expect(PluginDesiredState::Publisher).to have_received(:publish!).twice
  end

  it "quarantines an installed release revoked by prefixed digest" do
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    digest = Digest::SHA256.file(package.path).hexdigest
    release = PluginRelease.create!(name: "weather", version: "1.0", content_digest: digest,
      source: "bundled", trust_label: "verified", publisher_fingerprint: fingerprint, size_bytes: 0)
    installation = PluginInstallation.create!(plugin_name: "weather", plugin_release: release)

    store(revoked_releases: [ { name: "weather", version: "1.0", digest: "sha256:#{digest}" } ])
      .quarantine_revoked_installations!

    expect(installation.reload).to be_fleet_quarantined
  end

  it "generates a detached signature that verifies" do
    key_file = Tempfile.new
    key_file.write(key.private_to_pem)
    key_file.close
    signed = Syrus::PluginPackage::Signer.new(key_file.path).sign(package.path)
    expect(store.verify(package: package.path, signature: StringIO.new(signed), name: "weather", version: "1.0")).to be_trusted
  end
end
