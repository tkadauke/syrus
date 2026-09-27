require "rails_helper"

RSpec.describe OperatorBriefing::ReviewFinding, type: :model do
  let(:job) { Factories.job_with_run }
  let(:workflow) { job.workflows.first }
  let(:step) { workflow.steps.first }
  let(:run) { step.runs.first }

  it "marks earlier needs-work findings overridden when a later review passes" do
    first = described_class.record!(
      workflow: workflow,
      step: step,
      run: run,
      review_kind: "visual",
      iteration: 1,
      verdict: "needs_work",
      critique: "Button overlaps."
    )

    described_class.record!(
      workflow: workflow,
      step: step,
      run: nil,
      review_kind: "visual",
      iteration: 2,
      verdict: "approved",
      critique: "Overlap fixed."
    )

    expect(first.reload).to be_overridden
    expect(first.overridden_at).to be_present
  end

  it "upserts the same review submission identity" do
    described_class.record!(
      workflow: workflow,
      step: step,
      run: run,
      review_kind: "adversarial",
      iteration: 1,
      verdict: "needs_work",
      critique: "First"
    )

    described_class.record!(
      workflow: workflow,
      step: step,
      run: run,
      review_kind: "adversarial",
      iteration: 1,
      verdict: "approved",
      critique: "Second"
    )

    expect(described_class.count).to eq(1)
    expect(described_class.first).to have_attributes(verdict: "approved", critique: "Second")
  end
end
