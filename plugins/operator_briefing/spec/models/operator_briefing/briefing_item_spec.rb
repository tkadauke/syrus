require "rails_helper"

RSpec.describe OperatorBriefing::BriefingItem, type: :model do
  let(:job) { Factories.job_with_run }
  let(:workflow) { job.workflows.first }

  it "stores a decision-surface item with structured evidence and an optional source" do
    item = described_class.create!(
      briefing_id: 123,
      severity: "decision_required",
      source: workflow,
      narrative: "Operator should decide whether to ship the schema change.",
      evidence: [ { "file" => "db/schema.rb" } ]
    )

    expect(item).to be_persisted
    expect(item.source).to eq(workflow)
    expect(item.evidence).to eq([ { "file" => "db/schema.rb" } ])
  end

  it "validates the briefing severity and narrative" do
    item = described_class.new(severity: "urgent", narrative: "")

    expect(item).not_to be_valid
    expect(item.errors[:severity]).to include("is not included in the list")
    expect(item.errors[:narrative]).to include("can't be blank")
  end
end
