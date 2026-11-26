require "rails_helper"

RSpec.describe RuntimeImage do
  let(:namespace) { RuntimeImageNamespace.create!(name: "ns/a", owner_kind: "k", owner_ref: "1", provider_key: "synthetic") }
  let(:attrs) do
    { runtime_image_namespace: namespace, digest: "sha256:#{'c' * 64}", platform: "linux/amd64", source_kind: "k", source_ref: "r" }
  end

  it "defaults provenance to an empty object and availability to pending" do
    image = described_class.create!(attrs)
    expect(image.provenance).to eq({})
    expect(image).to be_pending
    expect(image.retention_state).to eq("default")
    expect(image.verification_state).to eq("unverified")
  end

  it "validates digest format and uniqueness per namespace and platform" do
    expect(described_class.new(attrs.merge(digest: "latest"))).not_to be_valid
    described_class.create!(attrs)
    expect(described_class.new(attrs)).not_to be_valid
    expect(described_class.new(attrs.merge(platform: "linux/arm64"))).to be_valid
  end

  it "only allows forward availability transitions" do
    image = described_class.create!(attrs)
    expect { image.mark_revoked!(reason: "x") }.to raise_error(RuntimeImage::InvalidTransition)
    image.mark_available!
    image.mark_revoked!(reason: "x")
    expect { image.mark_available! }.to raise_error(RuntimeImage::InvalidTransition)
    image.mark_deleted!
    expect { image.retain! }.to raise_error(RuntimeImage::InvalidTransition)
  end

  it "only treats available, unrevoked images as pullable" do
    image = described_class.create!(attrs.merge(verification_state: "candidate"))
    expect(described_class.pullable).to be_empty
    image.mark_available!
    expect(described_class.pullable).to contain_exactly(image)
  end

  it "releases retention" do
    image = described_class.create!(attrs)
    image.retain!(reason: "audit")
    expect(image.retained?).to be(true)
    image.release_retention!
    expect(image.reload.retention_state).to eq("default")
  end
end

RSpec.describe RuntimeImageNamespace do
  it "requires a well-formed unique name and an owner" do
    described_class.create!(name: "ns/a", owner_kind: "k", owner_ref: "1", provider_key: "p")
    expect(described_class.new(name: "ns/a", owner_kind: "k", owner_ref: "1", provider_key: "p")).not_to be_valid
    expect(described_class.new(name: "Bad Name", owner_kind: "k", owner_ref: "1", provider_key: "p")).not_to be_valid
    expect(described_class.new(name: "ns/b", owner_kind: "", owner_ref: "1", provider_key: "p")).not_to be_valid
  end
end
