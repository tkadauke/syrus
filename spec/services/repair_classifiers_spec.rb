require "rails_helper"

RSpec.describe RepairClassifiers do
  let(:workflow) { instance_double(Workflow) }
  let(:classification) do
    MainBranchFailureClassifier::Result.new(
      inherited: true,
      evidence: { "sha" => "abc" },
      inherited_names: [ "rspec" ],
      new_names: [],
      classifications: [ { "name" => "rspec", "inherited" => true } ]
    )
  end

  it "returns the main-health provider's classification through the generic point" do
    allow(MainBranchFailureClassifier).to receive(:call).and_return(classification)

    expect(described_class.classify(workflow:, failed_steps: [ :step ])).to eq(classification)
    expect(MainBranchFailureClassifier).to have_received(:call).with(
      workflow:, failed_grader_steps: [ :step ]
    )
  end

  it "has an absent result when no classifier claims the failure" do
    allow(MainBranchFailureClassifier).to receive(:call).and_return(
      classification.with(classifications: [])
    )

    expect(described_class.classify(workflow:)).to be_nil
  end
end
