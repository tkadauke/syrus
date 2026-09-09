require "rails_helper"

RSpec.describe WorkflowSourceSnapshot do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:step) { workflow.steps.find_by!(kind: "implement") }

  it "records source identity for a workflow" do
    snapshot = described_class.create!(
      workflow: workflow,
      creator_step: step,
      source_sha: "a" * 40,
      source_ref: "refs/syrus/checkpoints/runs/123",
      tree_sha: "b" * 40,
      published_at: Time.current
    )

    expect(snapshot).to be_persisted
    expect(workflow.source_snapshots).to include(snapshot)
    expect(step.created_source_snapshots).to include(snapshot)
  end

  it "requires either a tree SHA or a source fingerprint" do
    snapshot = described_class.new(
      workflow: workflow,
      creator_step: step,
      source_sha: "a" * 40,
      source_ref: "refs/syrus/checkpoints/runs/123",
      published_at: Time.current
    )

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:base]).to include("tree_sha or source_fingerprint must be present")
  end

  it "rejects a creator step from another workflow" do
    other_step = Factories.job.workflows.first.steps.find_by!(kind: "implement")
    snapshot = described_class.new(
      workflow: workflow,
      creator_step: other_step,
      source_sha: "a" * 40,
      source_ref: "refs/syrus/checkpoints/runs/123",
      tree_sha: "b" * 40,
      published_at: Time.current
    )

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:creator_step]).to include("must belong to the snapshot workflow")
  end

  it "returns the most recently published snapshot for a workflow" do
    older = described_class.create!(
      workflow: workflow,
      creator_step: step,
      source_sha: "a" * 40,
      source_ref: "refs/syrus/checkpoints/runs/older",
      tree_sha: "b" * 40,
      published_at: 2.minutes.ago
    )
    newer = described_class.create!(
      workflow: workflow,
      creator_step: step,
      source_sha: "c" * 40,
      source_ref: "refs/syrus/checkpoints/runs/newer",
      source_fingerprint: "sha256:#{'d' * 64}",
      published_at: 1.minute.ago
    )

    expect(described_class.current_for(workflow)).to eq(newer)
    expect(described_class.current_for(workflow)).not_to eq(older)
  end

  it "does not block workflow-owned cleanup" do
    described_class.create!(
      workflow: workflow,
      creator_step: step,
      source_sha: "a" * 40,
      source_ref: "refs/syrus/checkpoints/runs/123",
      tree_sha: "b" * 40,
      published_at: Time.current
    )

    expect { workflow.destroy! }.to change(described_class, :count).by(-1)
    expect(Step.exists?(step.id)).to eq(false)
  end
end
