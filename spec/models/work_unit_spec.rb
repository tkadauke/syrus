require "rails_helper"

RSpec.describe WorkUnit do
  def intent
    @intent ||= WorkIntent.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 123)
  end

  it "defaults blocked_details and exposes active/terminal predicates" do
    unit = described_class.create!(work_intent: intent, kind: "initial", state: "blocked", scope_type: "job", scope_id: 123,
                                   blocked_reason: "auto_retry_backoff")

    expect(unit.blocked_details).to eq({})
    expect(unit).to be_active
    expect(unit).not_to be_terminal
  end

  it "validates state and blocked reason vocabularies" do
    unit = described_class.new(work_intent: intent, kind: "initial", state: "bogus", scope_type: "job",
                               blocked_reason: "mystery")

    expect(unit).not_to be_valid
    expect(unit.errors[:state]).to be_present
    expect(unit.errors[:blocked_reason]).to be_present
  end

  it "can point at a child validation unit without changing the parent attempt" do
    parent = described_class.create!(work_intent: intent, kind: "auto_merge", state: "running", scope_type: "job", scope_id: 123)
    child = described_class.create!(work_intent: intent, kind: "landing_validation", state: "queued", scope_type: "job",
                                    scope_id: 123, parent_work_unit: parent)

    expect(parent.child_work_units).to contain_exactly(child)
  end
end
