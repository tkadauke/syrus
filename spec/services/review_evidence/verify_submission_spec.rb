require "rails_helper"

RSpec.describe ReviewEvidence::VerifySubmission do
  let(:job) { Factories.job }
  let(:run) { job.latest_workflow.steps.find_by!(kind: "implement").runs.create!(job: job, trigger_kind: "initial") }
  let(:evidence) do
    ReviewEvidence.create!(
      run: run, workflow: run.workflow, step: run.step, review_kind: "adversarial",
      provider: "codex", model: "gpt-test", reviewed_base_sha: "a" * 40,
      reviewed_head_sha: "b" * 40, canonical_diff_sha256: "c" * 64,
      prompt_version: "1", checklist_version: "d" * 64, tool_policy_version: "1"
    )
  end

  it "accepts the exact frozen head and canonical diff" do
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot)
      .and_return(head_sha: "b" * 40, sha256: "c" * 64)

    expect(described_class.call!(evidence: evidence, workspace_path: "/workspace")).to eq(evidence)
    expect(evidence.reload.state).to eq("pending")
  end

  it "monotonically marks changed source stale with a typed mismatch" do
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot)
      .and_return(head_sha: "e" * 40, sha256: "f" * 64)

    expect {
      described_class.call!(evidence: evidence, workspace_path: "/workspace")
    }.to raise_error(ReviewEvidence::VerifySubmission::Mismatch) { |error|
      expect(error.code).to eq("review_evidence_mismatch")
    }

    expect(evidence.reload).to have_attributes(state: "stale", terminal_failure_code: "review_evidence_mismatch")
  end
end
