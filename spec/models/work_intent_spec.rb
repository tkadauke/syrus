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

  it "waits and returns to requested with typed domain reason details" do
    intent = described_class.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 123)

    intent.wait!(reason: "dependency", wait_until: 5.minutes.from_now, details: { "blocked_by_job_ids" => [ 9 ] })

    expect(intent).to have_attributes(state: "waiting", wait_reason: "dependency")
    expect(intent.wait_details).to include("blocked_by_job_ids" => [ 9 ])
    expect(intent).not_to be_ready

    intent.request!

    expect(intent).to have_attributes(state: "requested", wait_reason: nil, wait_until: nil)
    expect(intent.wait_details).to eq({})
    expect(intent).to be_ready
  end

  it "marks satisfied, failed, and cancelled terminal intent outcomes" do
    satisfied = described_class.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 123)
    failed = described_class.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 124)
    cancelled = described_class.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 125)

    satisfied.satisfy!
    failed.fail!
    cancelled.cancel!

    expect(satisfied).to be_satisfied
    expect(satisfied.satisfied_at).to be_present
    expect(failed).to be_failed
    expect(cancelled).to be_cancelled
    expect(cancelled.cancelled_at).to be_present
  end
end
