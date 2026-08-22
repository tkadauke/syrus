require "rails_helper"

RSpec.describe WorkUnitLock do
  def work_unit
    @work_unit ||= begin
      intent = WorkIntent.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 123)
      WorkUnit.create!(work_intent: intent, kind: "initial", state: "queued", scope_type: "job", scope_id: 123)
    end
  end

  it "sets acquired_at and enforces unique lock keys" do
    lock = described_class.create!(work_unit: work_unit, lock_key: "job:123")
    duplicate = described_class.new(work_unit: work_unit, lock_key: "job:123")

    expect(lock.acquired_at).to be_present
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:lock_key]).to be_present
  end
end
