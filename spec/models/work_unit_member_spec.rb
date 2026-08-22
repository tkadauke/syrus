require "rails_helper"

RSpec.describe WorkUnitMember do
  def work_unit
    @work_unit ||= begin
      intent = WorkIntent.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 123)
      WorkUnit.create!(work_intent: intent, kind: "initial", state: "queued", scope_type: "job", scope_id: 123)
    end
  end

  it "captures an immutable job membership role for a work unit" do
    job = Factories.job_record
    member = described_class.create!(work_unit: work_unit, job: job, role: "primary")

    duplicate = described_class.new(work_unit: work_unit, job: job, role: "primary")

    expect(member).to be_persisted
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:job_id]).to be_present
  end
end
