require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::CandidateResolver do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let!(:grader) do
    Step.create!(workflow:, kind: "grader", position: 10, state: "failed", details: {
      "name" => "rspec", "target_label" => "//:grade/rspec", "required" => true,
      "technically_overridable" => true, "command" => "bin/rspec", "exit_code" => 1,
      "output" => "false positive", "source_snapshot" => { "tree_sha" => "b" * 40 },
      "target_fingerprints" => { "command_fingerprint" => "command-v1" }
    })
  end

  before do
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, "a" * 40)
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_BASE_SHA_KEY, "c" * 40)
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, "plan-v1")
  end

  it "reconstructs an exact technically-overridable grader candidate" do
    candidate = described_class.for_job(job).sole

    expect(candidate.as_json).to include(
      gate_kind: "implementation_grader", gate_identity: "//:grade/rspec",
      candidate_head_sha: "a" * 40, candidate_tree_sha: "b" * 40,
      technically_overridable: true
    )
    expect(candidate.fingerprint.digest).to match(/\A[0-9a-f]{64}\z/)
  end

  it "rejects a stale or invented fingerprint" do
    expect { described_class.new(job).find!("invented") }
      .to raise_error(described_class::NotFound, /stale or unavailable/)
  end

  it "reconstructs exact panel-review evidence for the failed member" do
    grader.destroy!
    reviewed_sha = "d" * 40
    vote = {
      "iteration" => 2, "step_id" => 91, "run_id" => 92,
      "panel_id" => "security-panel", "provider" => "codex", "model" => "gpt-5",
      "verdict" => "needs_work", "critique" => "False positive."
    }
    workflow.set_artifact!("security_review_iterations", [
      vote,
      vote.merge("aggregate" => true),
      vote.merge("iteration" => 1, "provider" => "claude")
    ])
    collect = Step.create!(
      workflow:, kind: "review_panel_collect", position: 20, iteration: 2,
      details: { "panel_review_kind" => "security_review", "panel_id" => "security-panel",
                 "reviewed_head_sha" => reviewed_sha }
    )

    candidate = described_class.for_job(job).sole

    expect(candidate.step).to eq(collect)
    expect(candidate.as_json).to include(
      gate_kind: "review", candidate_head_sha: reviewed_sha,
      gate_identity: "security_review:security-panel:codex:gpt-5",
      evidence_digest: WorkflowOutcomeOverrides::ReviewVerdict.evidence_digest(vote)
    )
  end

  it "does not offer review evidence that an override already made effective" do
    grader.destroy!
    workflow.set_artifact!("adversarial_review_iterations", [ {
      "iteration" => 1, "step_id" => 91, "verdict" => "needs_work",
      "effective_verdict" => "approved", "outcome_override_id" => 7
    } ])
    Step.create!(workflow:, kind: "adversarial_review", position: 20, iteration: 1,
      details: { "reviewed_head_sha" => "d" * 40 })

    expect(described_class.for_job(job)).to be_empty
  end
end
