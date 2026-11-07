require "rails_helper"

RSpec.describe ReviewEvidence::Capture do
  let(:job) { Factories.job }
  let(:step) { job.latest_workflow.steps.find_by!(kind: "implement") }
  let(:run) do
    step.runs.create!(job: job, trigger_kind: "initial", agent_provider: "codex", model: "gpt-pinned")
  end

  it "freezes lineage, provider selection, revisions, diff, and policy versions" do
    allow(ReviewEvidence::CanonicalDiff).to receive(:resolve).and_return("a" * 40)
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot).and_return(head_sha: "b" * 40, sha256: "c" * 64)

    evidence = described_class.call(
      run: run, workspace_path: "/workspace", review_kind: "security",
      base_ref: "origin/main", checklist: ["authorization", "secrets"]
    )

    expect(evidence).to have_attributes(
      run_id: run.id, workflow_id: run.workflow_id, step_id: run.step_id,
      provider: "codex", model: "gpt-pinned", review_kind: "security",
      reviewed_base_sha: "a" * 40, reviewed_head_sha: "b" * 40,
      canonical_diff_sha256: "c" * 64, state: "pending"
    )
    expect(evidence.checklist_version).to eq(Digest::SHA256.hexdigest('["authorization","secrets"]'))
  end

  it "pins the workflow model on the Run before capturing evidence" do
    run.update!(model: nil)
    run.workflow.update!(model: "gpt-workflow-default")
    allow(ReviewEvidence::CanonicalDiff).to receive(:resolve).and_return("a" * 40)
    allow(ReviewEvidence::CanonicalDiff).to receive(:snapshot).and_return(head_sha: "b" * 40, sha256: "c" * 64)

    evidence = described_class.call(
      run: run, workspace_path: "/workspace", review_kind: "adversarial", base_ref: "origin/main"
    )

    expect(run.reload.model).to eq("gpt-workflow-default")
    expect(evidence.model).to eq("gpt-workflow-default")
  end

  it "refuses to fabricate a model when routing did not resolve one" do
    run.update!(model: nil)
    run.workflow.update!(model: nil)
    provider = class_double(AgentProviders::Base, resolve_model: nil)
    allow(AgentProviders).to receive(:for).with("codex").and_return(provider)

    expect {
      described_class.call(
        run: run, workspace_path: "/workspace", review_kind: "adversarial", base_ref: "origin/main"
      )
    }.to raise_error(ArgumentError, /model must be resolved/)
  end
end
