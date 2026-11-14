require "rails_helper"

RSpec.describe App::ProposerPayload do
  it "is the single builder used by chat proposal payloads" do
    proposer = Factories.user(email_address: "adrian@example.com")
    record = Struct.new(:proposer).new(proposer)

    expect(App::ChatMessagePayload.proposer_json(record)).to eq(described_class.for(record))
    expect(described_class.for(record)).to eq(
      type: "human", id: proposer.id, label: proposer.display_name, handle: "adrian"
    )
  end

  it "returns nil when the record has no proposer" do
    expect(described_class.for(Struct.new(:proposer).new(nil))).to be_nil
  end
end
