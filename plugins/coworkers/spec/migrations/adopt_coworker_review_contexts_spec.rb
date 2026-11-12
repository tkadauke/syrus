require "rails_helper"
require Rails.root.join("plugins/coworkers/db/migrate/20261112234500_adopt_coworker_review_contexts")

RSpec.describe AdoptCoworkerReviewContexts do
  let(:owner) { Factories.user }
  let(:job) { Factories.job(user: owner, repository: Factories.repository(user: owner)) }
  let(:step) { Step.create!(workflow: job.latest_workflow, kind: "coworker_review", position: 97) }
  let(:run) { step.runs.create!(job: job, trigger_kind: "initial", agent_provider: "codex", model: "m") }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", state: "active",
      workspace_repo: Factories.repository(user: owner).remote_url)
  end
  let(:evidence) do
    ReviewEvidence.create!(run:, workflow: run.workflow, step:, reviewer: coworker, review_kind: "coworker",
      provider: "codex", model: "m", reviewed_base_sha: "a" * 40, reviewed_head_sha: "b" * 40,
      canonical_diff_sha256: "c" * 64, prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1")
  end

  it "backfills opaque envelopes for historical coworker evidence and is idempotent" do
    context = Coworkers::ReviewContext.create!(run:, review_evidence_id: evidence.id, coworker:,
      manifest: { "protected_prompt" => { "sha256" => "safe" } }, exact_context: { "protected_prompt" => "secret" },
      workspace_path: "/tmp/x")

    2.times { described_class.new.up }

    expect(evidence.reload.review_target).to include(
      "type" => "coworker", "reference" => coworker.id.to_s, "display" => include("name" => "Maya", "handle" => "maya")
    )
    expect(evidence.context_manifest).to eq("protected_prompt" => { "sha256" => "safe" })
    expect(context.reload).to have_attributes(
      idempotency_key: Coworkers::ReviewContext.idempotency_key_for(evidence.id),
      evidence_snapshot: include("reviewed_head_sha" => "b" * 40)
    )
  end

  it "leaves already-enveloped evidence untouched" do
    evidence.update_columns(target: { "type" => "coworker", "reference" => "keep" })

    described_class.new.up

    expect(evidence.reload.review_target["reference"]).to eq("keep")
  end
end
