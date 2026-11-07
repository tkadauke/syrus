require "rails_helper"

RSpec.describe Coworkers::ReviewContextContributor do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job_with_run(user:, owner_user: user, repository:) }
  let(:run) { job.runs.first }
  let(:context) { double("review context", id: 19, manifest: { "protected_prompt" => { "sha256" => "abc" } }) }
  let(:persisted) { double("persisted context", id: 19, updated_at: Time.zone.parse("2026-11-07 12:00:00"), persisted_commit_sha: nil) }
  let(:coworker) do
    double(
      "reviewer",
      prepare_review_context!: context,
      review_context_prompt: "restricted exact text",
      finalize_review_memory!: persisted
    )
  end

  before do
    allow(ReviewerTargets).to receive(:resolve).and_return(record: coworker)
  end

  it "adapts protected context without exposing the coworker record to core" do
    expect(described_class.prepare(target: { type: "coworker", reference: "7" }, run:, evidence: nil, criteria: []))
      .to eq(manifest: context.manifest, restricted_text: "restricted exact text", persistence_token: "19")
  end

  it "binds its contributed tools to the coworker-review workflow capability" do
    expect(described_class.tool_capability(type: "coworker", reference: "7")).to eq(:submit_coworker_review)
  end

  it "returns an opaque idempotent persistence receipt" do
    expect(described_class.persist(
      target: { type: "coworker", reference: "7" }, run:, context: {}, verdict: "approved",
      update: { key_learning: "Keep the boundary narrow." }
    )).to include(owner: "coworkers", type: "review_memory", key: "19", persisted_at: "2026-11-07T12:00:00Z")
  end

  it "rejects a post-verdict update without a key learning" do
    expect {
      described_class.persist(target: { type: "coworker", reference: "7" }, run:, context: {}, verdict: "approved", update: {})
    }.to raise_error(KeyError, /key_learning/)
  end
end
