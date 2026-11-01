require "rails_helper"

RSpec.describe Workflows::Unland do
  it "selects a non-agentic prepare and grader-only validation chain" do
    workflow = described_class.instantiate(job: Factories.job)

    expect(described_class.trigger_kind).to eq("unland")
    expect(described_class.agentic?).to be(false)
    expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[prepare grader_fanout grader_collect])
    expect(Workflow::TriggerKind.template_for("unland")).to eq(described_class)
  end
end
