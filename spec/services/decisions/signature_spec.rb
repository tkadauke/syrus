require "rails_helper"

RSpec.describe Decisions::Signature do
  # The whole point: two occurrences of the same problem must fingerprint the
  # same, or a decision never matches twice and the queue stops compounding.
  it "is stable across occurrences of the same problem" do
    first = described_class.for(Problem[:grader_failure, evidence: { grader_name: "rspec", run_id: 1 }])
    second = described_class.for(Problem[:grader_failure, evidence: { grader_name: "rspec", run_id: 99 }])

    expect(first).to eq(second)
  end

  it "differs when the significant evidence differs" do
    rspec = described_class.for(Problem[:grader_failure, evidence: { grader_name: "rspec" }])
    rubocop = described_class.for(Problem[:grader_failure, evidence: { grader_name: "rubocop" }])

    expect(rspec).not_to eq(rubocop)
  end

  it "differs when the problem code differs" do
    expect(described_class.for(Problem[:grader_failure, evidence: { grader_name: "rspec" }]))
      .not_to eq(described_class.for(Problem[:timeout, evidence: { grader_name: "rspec" }]))
  end

  it "is the bare code when no significant evidence was recorded" do
    expect(described_class.for(Problem[:timeout, evidence: { run_id: 5 }])).to eq("timeout")
  end

  it "does not depend on evidence ordering" do
    a = described_class.for(Problem[:grader_failure, evidence: { grader_name: "rspec", exit_status: 1 }])
    b = described_class.for(Problem[:grader_failure, evidence: { exit_status: 1, grader_name: "rspec" }])

    expect(a).to eq(b)
  end
end
