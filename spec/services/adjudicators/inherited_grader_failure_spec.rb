require "rails_helper"

RSpec.describe Adjudicators::InheritedGraderFailure do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:step) { workflow.steps.first }

  def classifier_result(inherited:, inherited_names: [], new_names: [])
    MainBranchFailureClassifier::Result.new(
      inherited: inherited, evidence: {}, inherited_names: inherited_names,
      new_names: new_names, classifications: []
    )
  end

  it "declines for a problem that is not a grader failure" do
    expect(described_class.adjudicate(problem: Problem[:timeout], workflow: workflow)).to be_inconclusive
  end

  it "declines when there is no workflow to reason about" do
    expect(described_class.adjudicate(problem: Problem[:grader_failure])).to be_inconclusive
  end

  it "dismisses a grader that was already failing on the base" do
    allow(MainBranchFailureClassifier).to receive(:call)
      .and_return(classifier_result(inherited: true, inherited_names: [ "rspec" ]))

    verdict = described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow, step: step)

    expect(verdict).to be_dismiss
    expect(verdict.reason).to eq("grader_already_failing_on_base")
    expect(verdict.evidence).to eq(inherited_names: [ "rspec" ], new_names: [])
  end

  it "declines when the failure is new on this branch" do
    allow(MainBranchFailureClassifier).to receive(:call)
      .and_return(classifier_result(inherited: false, new_names: [ "rspec" ]))

    expect(described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow, step: step))
      .to be_inconclusive
  end
end
