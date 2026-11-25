require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::Fingerprint do
  let(:attributes) do
    described_class::ATTRIBUTES.index_with { |attribute| "#{attribute}-value" }
  end

  it "copies every bound attribute from a record" do
    record_class = Struct.new(*described_class::ATTRIBUTES, keyword_init: true)

    fingerprint = described_class.from(record_class.new(**attributes))

    expect(fingerprint.to_h).to eq(attributes)
  end

  it "produces a deterministic digest independent of keyword order" do
    fingerprint = described_class.new(**attributes)
    reordered = described_class.new(**attributes.to_a.reverse.to_h)

    expect(fingerprint.digest).to eq(reordered.digest)
  end

  it "binds the digest to every fingerprint attribute" do
    digest = described_class.new(**attributes).digest

    described_class::ATTRIBUTES.each do |attribute|
      changed = described_class.new(**attributes.merge(attribute => "changed"))
      expect(changed.digest).not_to eq(digest), "expected #{attribute} to affect the digest"
    end
  end

  it "rejects unknown attributes" do
    expect {
      described_class.new(**attributes, unexpected: "value")
    }.to raise_error(ArgumentError, /unknown fingerprint attributes: unexpected/)
  end
end
