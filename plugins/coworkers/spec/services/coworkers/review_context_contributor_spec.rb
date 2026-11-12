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

  describe ".reviewer_for" do
    let(:owner) { Factories.user }
    let(:real) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", state: "active", workspace_repo: Factories.repository(user: owner).remote_url) }
    let(:step) { Step.create!(workflow: job.latest_workflow, kind: "coworker_review", position: 98) }
    let(:review_run) { step.runs.create!(job: job, trigger_kind: "initial", agent_provider: "codex", model: "m") }

    def evidence(**attrs)
      ReviewEvidence.create!({ run: review_run, workflow: review_run.workflow, step:, review_kind: "coworker",
        provider: "codex", model: "m", reviewed_base_sha: "a" * 40, reviewed_head_sha: "b" * 40,
        canonical_diff_sha256: "c" * 64, prompt_version: "1", checklist_version: "d" * 64,
        tool_policy_version: "1" }.merge(attrs))
    end

    it "reads the opaque target envelope" do
      evidence(target: { "type" => "coworker", "reference" => real.id.to_s })

      expect(described_class.reviewer_for(review_run)).to eq(real)
    end

    it "falls back to the legacy polymorphic reviewer for unbackfilled historical rows" do
      evidence(reviewer: real)

      expect(described_class.reviewer_for(review_run)).to eq(real)
    end

    it "is nil without evidence" do
      expect(described_class.reviewer_for(review_run)).to be_nil
    end
  end

  it "builds operator links only from the target reference" do
    allow(Coworkers::Coworker).to receive(:find_by).with(id: "7").and_return(double(review_evidence_links: { "journal" => "/j" }))

    expect(described_class.operator_links(target: { "reference" => "7" }, run:, user: Factories.user)).to eq("journal" => "/j")
  end
end
