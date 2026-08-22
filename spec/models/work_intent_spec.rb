require "rails_helper"

RSpec.describe WorkIntent do
  it "defaults requested_at and wait_details for new intents" do
    intent = described_class.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 123)

    expect(intent.requested_at).to be_present
    expect(intent.wait_details).to eq({})
    expect(intent).to be_ready
  end

  it "validates state and wait reason vocabularies" do
    intent = described_class.new(kind: "initial", state: "bogus", scope_type: "job", wait_reason: "mystery")

    expect(intent).not_to be_valid
    expect(intent.errors[:state]).to be_present
    expect(intent.errors[:wait_reason]).to be_present
  end
end
