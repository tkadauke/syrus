require "rails_helper"

RSpec.describe ReviewEvidence::ArtifactPresentation do
  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.steps.find_by!(kind: "implement") }
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }

  it "marks legacy entries without inventing provenance" do
    entry = { "iteration" => 1, "verdict" => "approved", "critique" => "Legacy review" }

    expect(described_class.call([ entry ])).to eq([
      entry.merge("review_evidence" => { "state" => "legacy" })
    ])
  end

  it "prevents stale bound evidence from presenting as an approval" do
    evidence = ReviewEvidence.create!(
      run: run, workflow: workflow, step: step, review_kind: "adversarial",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    )
    evidence.mark_stale!(code: "review_evidence_mismatch", details: { current_head_sha: "e" * 40 })

    presented = described_class.call([
      { "review_evidence_id" => evidence.id, "verdict" => "approved", "critique" => "Clean" }
    ]).sole

    expect(presented).to include("verdict" => "stale")
    expect(presented.fetch("review_evidence")).to include(
      "id" => evidence.id,
      "state" => "stale",
      "terminal_failure_code" => "review_evidence_mismatch"
    )
  end

  it "presents the billed review cost without exposing operator links by default" do
    run.update!(cost_usd: 0.125)
    evidence = ReviewEvidence.create!(
      run: run, workflow: workflow, step: step, review_kind: "adversarial",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    )

    presented = described_class.call([ { "review_evidence_id" => evidence.id, "verdict" => "approved" } ]).sole

    expect(presented).to include("cost_usd" => 0.125)
    expect(presented).not_to have_key("operator_links")
  end

  it "renders immutable target, context, and persistence snapshots without a live plugin record" do
    evidence = ReviewEvidence.create!(
      run: run, workflow: workflow, step: step, review_kind: "contributed_review",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1",
      target_envelope: { "type" => "removed_plugin", "reference" => "opaque-1" },
      target_snapshot: { "display" => { "name" => "Historical reviewer" } },
      context_envelope: { "owner" => "removed_plugin", "manifest" => { "sha256" => "safe" } },
      persistence_envelope: { "owner" => "removed_plugin", "type" => "journal", "key" => "receipt-1", "version" => 1 }
    )

    payload = described_class.call([ { "review_evidence_id" => evidence.id, "verdict" => "approved" } ]).sole

    expect(payload.fetch("review_evidence")).to include(
      "target" => { "display" => { "name" => "Historical reviewer" } },
      "context" => include("manifest" => { "sha256" => "safe" }),
      "persistence" => include("key" => "receipt-1")
    )
  end
end
