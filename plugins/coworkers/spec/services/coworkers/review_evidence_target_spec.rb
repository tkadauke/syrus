require "rails_helper"

RSpec.describe Coworkers::ReviewEvidenceTarget do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:job) { Factories.job_with_run(user: owner, owner_user: owner, repository:) }
  let(:run) { job.runs.first }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-evidence-target",
      state: "active", workspace_repo: repository.remote_url)
  end

  it "dual-reads the opaque target and legacy polymorphic identity" do
    current = ReviewEvidence.new(run:, target_envelope: { "type" => "coworker", "reference" => coworker.id.to_s })
    allow(ReviewerTargets).to receive(:resolve).and_return(record: coworker)
    expect(described_class.resolve(current, run:)).to eq(coworker)

    legacy = ReviewEvidence.new(run:, reviewer: coworker)
    expect(described_class.resolve(legacy, run:)).to eq(coworker)
  end
end
