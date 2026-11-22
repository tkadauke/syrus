require "rails_helper"

RSpec.describe PluginArtifacts do
  let(:body) { "plugin archive bytes" }
  let(:digest) { Digest::SHA256.hexdigest(body) }
  let(:release) do
    PluginRelease.create!(name: "weather", version: "1.2.3", content_digest: digest,
      source: "upload", trust_label: "unsigned_local", size_bytes: body.bytesize)
  end

  def signed_registry_release
    key = Ed25519::SigningKey.generate
    public_key = key.verify_key.to_bytes
    fingerprint = Digest::SHA256.hexdigest(public_key)
    signature = JSON.generate(
      algorithm: "ed25519", digest:, public_key: Base64.strict_encode64(public_key), fingerprint:,
      signature: Base64.strict_encode64(key.sign(digest))
    )
    release.update!(source: "registry", signature:)
    [ fingerprint, Syrus::PluginPackage::TrustStore.new(
      "publishers" => [ { "fingerprint" => fingerprint, "label" => "community" } ]
    ) ]
  end

  it "stores a verified artifact at its content-addressed key" do
    described_class.store!(release, StringIO.new(body))

    expect(release.archive.blob.key).to eq("plugins/artifacts/#{digest}")
    expect(release.archive.download).to eq(body)
  end

  it "refuses a registry artifact unless its publisher signature is trusted" do
    release.update!(source: "registry")

    expect { described_class.store!(release, StringIO.new(body), trust_store: Syrus::PluginPackage::TrustStore.new({})) }
      .to raise_error(PluginArtifacts::TrustVerificationFailed, /unsigned packages/)
    expect(release.archive).not_to be_attached
  end

  it "stores a trusted registry artifact with the verified publisher identity" do
    fingerprint, trust_store = signed_registry_release
    allow(Syrus::PluginPackage::TrustStore).to receive(:cached).and_return(trust_store)

    described_class.store!(release, StringIO.new(body))

    expect(release.reload).to have_attributes(trust_label: "community", publisher_key_fingerprint: fingerprint)
    expect(release.archive).to be_attached
  end

  it "refuses a registry artifact whose publisher was revoked in the cached trust store" do
    fingerprint, trust_store = signed_registry_release
    trust_store.revoked_keys.add(fingerprint)
    allow(Syrus::PluginPackage::TrustStore).to receive(:cached).and_return(trust_store)

    expect { described_class.store!(release, StringIO.new(body)) }
      .to raise_error(PluginArtifacts::TrustVerificationFailed, /key has been revoked/)
    expect(release.archive).not_to be_attached
  end

  it "rejects bytes that do not match the declared digest" do
    expect { described_class.store!(release, StringIO.new("tampered")) }
      .to raise_error(PluginArtifacts::DigestMismatch, /digest/)
    expect(release.archive).not_to be_attached
  end

  it "works with the local-volume disk service used by SQLite installations" do
    service = ActiveStorage::Blob.services.fetch(:local_volume)
    allow(ActiveStorage::Blob).to receive(:service).and_return(service)

    described_class.store!(release, StringIO.new(body))

    expect(service.download("plugins/artifacts/#{digest}")).to eq(body)
  ensure
    service&.delete("plugins/artifacts/#{digest}")
  end
end
