require "rails_helper"

RSpec.describe Adjudicators::ValidatedLanding do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }

  it "declines for a problem that is not a grader failure" do
    expect(described_class.adjudicate(problem: Problem[:timeout], workflow: workflow)).to be_inconclusive
  end

  it "declines when the workflow recorded no head to check" do
    expect(described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow)).to be_inconclusive
  end

  it "dismisses when this exact head already graded green" do
    workflow.set_artifact!("head_sha", "abc123")
    allow(LandingValidationCache).to receive(:valid_head_for?).with(job: job, head_sha: "abc123").and_return(true)

    verdict = described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow)

    expect(verdict).to be_dismiss
    expect(verdict.evidence).to eq(head_sha: "abc123")
  end

  # A validation for a different head says nothing about this one.
  it "declines when the recorded validation is for another head" do
    workflow.set_artifact!("head_sha", "abc123")
    allow(LandingValidationCache).to receive(:valid_head_for?).and_return(false)

    expect(described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow)).to be_inconclusive
  end
end
