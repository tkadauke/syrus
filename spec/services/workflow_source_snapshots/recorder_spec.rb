require "rails_helper"

RSpec.describe WorkflowSourceSnapshots::Recorder do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:step) { workflow.steps.find_by!(kind: "implement") }

  it "records and looks up the current source snapshot for a workflow" do
    snapshot = described_class.record!(
      workflow: workflow,
      creator_step: step,
      source_sha: "a" * 40,
      source_ref: "refs/syrus/checkpoints/runs/123",
      tree_sha: "b" * 40,
      published_at: Time.zone.parse("2026-09-09 12:30:00")
    )

    expect(snapshot).to be_persisted
    expect(snapshot.source_sha).to eq("a" * 40)
    expect(snapshot.tree_sha).to eq("b" * 40)
    expect(described_class.current_for(workflow)).to eq(snapshot)
  end

  it "reuses the same workflow/source SHA record when diagnostics are refreshed" do
    described_class.record!(
      workflow: workflow,
      creator_step: step,
      source_sha: "a" * 40,
      source_ref: "refs/syrus/checkpoints/runs/123",
      tree_sha: "b" * 40,
      published_at: 2.minutes.ago
    )

    snapshot = described_class.record!(
      workflow: workflow,
      creator_step: step,
      source_sha: "a" * 40,
      source_ref: "refs/syrus/checkpoints/runs/123",
      source_fingerprint: "sha256:#{'c' * 64}",
      published_at: 1.minute.ago
    )

    expect(WorkflowSourceSnapshot.count).to eq(1)
    expect(snapshot.source_fingerprint).to eq("sha256:#{'c' * 64}")
    expect(snapshot.published_at).to be_within(1.second).of(1.minute.ago)
  end
end
