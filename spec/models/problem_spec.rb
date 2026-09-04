require "rails_helper"

RSpec.describe Problem do
  it "carries a code and its evidence" do
    problem = described_class[:branch_diverged, evidence: { expected_sha: "abc", observed_sha: "def" }]

    expect(problem.code).to eq("branch_diverged")
    expect(problem.evidence).to eq(expected_sha: "abc", observed_sha: "def")
  end

  it "answers the registry's metadata for its code" do
    problem = described_class[:merge_train_rebuild_required]

    expect(problem.scope).to eq(:unit)
    expect(problem.retryable?).to be(false)
    expect(problem.default_remediation).to eq(:rebuild_unit)
  end

  it "builds from another plane's name for the same event" do
    problem = described_class.resolve("remote_branch_advanced_rebase_conflict", evidence: { branch: "syrus/1" })

    expect(problem.code).to eq("branch_diverged")
    expect(problem.evidence).to eq(branch: "syrus/1")
  end

  it "returns nil rather than raising for an unmapped name" do
    expect(described_class.resolve("not_a_real_failure")).to be_nil
  end

  it "raises for an unknown code constructed directly" do
    expect { described_class[:not_a_real_failure] }.to raise_error(ArgumentError, /unknown problem code/)
  end

  it "compares by code and evidence" do
    expect(described_class[:timeout, evidence: { after: 30 }]).to eq(described_class[:timeout, evidence: { after: 30 }])
    expect(described_class[:timeout, evidence: { after: 30 }]).not_to eq(described_class[:timeout])
  end

  it "is frozen once built" do
    expect(described_class[:timeout]).to be_frozen
  end
end
