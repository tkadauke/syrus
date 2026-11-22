require "rails_helper"
require "base64"
require "ed25519"

RSpec.describe Syrus::PluginPackage::Verifier do
  let(:package) { StringIO.new("package bytes") }
  let(:key) { Ed25519::SigningKey.generate }
  let(:public_key) { key.verify_key.to_bytes }
  let(:fingerprint) { Digest::SHA256.hexdigest(public_key) }
  let(:digest) { Digest::SHA256.hexdigest("package bytes") }
  let(:signature) do
    StringIO.new(JSON.generate(
      algorithm: "ed25519", digest:, public_key: Base64.strict_encode64(public_key), fingerprint:,
      signature: Base64.strict_encode64(key.sign(digest))
    ))
  end

  def store(label: "verified", revoked_keys: [])
    Syrus::PluginPackage::TrustStore.new(
      "publishers" => [ { "fingerprint" => fingerprint, "label" => label } ],
      "revoked_keys" => revoked_keys
    )
  end

  %w[official verified community].each do |label|
    it "returns the #{label} trust label" do
      result = described_class.new(package:, signature:, trust_store: store(label:)).call
      expect(result).to be_valid
      expect(result.trust_label).to eq(label)
      expect(result.fingerprint).to eq(fingerprint)
    end
  end

  it "accepts an unsigned package only as unsigned local" do
    result = described_class.new(package:, signature: nil, trust_store: store, local: true).call
    expect(result).to be_valid
    expect(result.trust_label).to eq("unsigned_local")

    expect(described_class.new(package:, signature: nil, trust_store: store).call.errors).to include(/unsigned packages/)
  end

  it "rejects tampering and the wrong key" do
    package.string.replace("tampered")
    expect(described_class.new(package:, signature:, trust_store: store).call.errors).to include(/digest does not match/)

    package.string.replace("package bytes")
    other = Ed25519::SigningKey.generate
    envelope = JSON.parse(signature.string).merge("signature" => Base64.strict_encode64(other.sign(digest)))
    expect(described_class.new(package:, signature: StringIO.new(JSON.generate(envelope)), trust_store: store).call.errors).to include(/verification failed/)
  end

  it "rejects a revoked publisher key" do
    result = described_class.new(package:, signature:, trust_store: store(revoked_keys: [ fingerprint ])).call
    expect(result.errors).to include(/key has been revoked/)
  end

  it "rejects a revoked release" do
    trust_store = Syrus::PluginPackage::TrustStore.new(
      "publishers" => [ { "fingerprint" => fingerprint, "label" => "verified" } ],
      "revoked_releases" => [ { "name" => "weather", "version" => "1.2.3", "digest" => digest } ]
    )
    result = described_class.new(package:, signature:, trust_store:, name: "weather", version: "1.2.3").call
    expect(result.errors).to include(/release has been revoked/)
  end
end
