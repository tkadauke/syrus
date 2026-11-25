require "rails_helper"

RSpec.describe RuntimeImages::BuildRequests do
  let(:service) { described_class.new }
  let(:files) { { "smoke-test" => "#!/bin/sh\ntrue\n", "Dockerfile" => "FROM scratch\n" } }

  it "deduplicates identical file maps independently of wall clock and RubyGems archive configuration" do
    first = travel_to(Time.utc(2026, 1, 1)) { submit }
    allow(Gem).to receive(:source_date_epoch).and_return(Time.utc(2030, 1, 1))
    second = travel_to(Time.utc(2027, 1, 1)) { submit }

    expect(second).to eq(first)
    expect(RuntimeImageBuildRequest.where(id: first.id)).to contain_exactly(first)
  end

  private

  def submit
    service.submit(owner_kind: "test", owner_ref: "stable-source", source_kind: "test", source_ref: "source",
                   files: files, recipe: { "dockerfile" => "Dockerfile" }, requester_kind: "test", requester_ref: "1")
  end
end
