require "rails_helper"

RSpec.describe WorkflowSourceSnapshot, :ci_only do
  let(:job) { Factories.job_record(state: "running") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }
  let(:step) { Step.create!(workflow: workflow, kind: "implement", position: 0, state: "succeeded") }

  it "requires either a tree SHA or fingerprint" do
    snapshot = described_class.new(
      workflow: workflow,
      creator_step: step,
      source_sha: "abc123",
      source_ref: "refs/heads/syrus/direct-4649",
      published_at: Time.current
    )

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:base]).to include("tree_sha or fingerprint must be present")
  end

  it "requires a creator step" do
    snapshot = described_class.new(
      workflow: workflow,
      source_sha: "abc123",
      source_ref: "refs/heads/syrus/direct-4649",
      tree_sha: "tree123",
      published_at: Time.current
    )

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:creator_step]).to include("must exist")
  end

  it "requires the creator step to belong to the same workflow" do
    other_workflow = Workflow.create!(job: job, trigger_kind: "retry", state: "running")
    other_step = Step.create!(workflow: other_workflow, kind: "implement", position: 0, state: "succeeded")
    snapshot = described_class.new(
      workflow: workflow,
      creator_step: other_step,
      source_sha: "abc123",
      source_ref: "refs/heads/syrus/direct-4649",
      tree_sha: "tree123",
      published_at: Time.current
    )

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:creator_step]).to include("must belong to the same workflow")
  end

  it "does not block workflow-owned cleanup from destroying creator steps" do
    described_class.create!(
      workflow: workflow,
      creator_step: step,
      source_sha: "abc123",
      source_ref: "refs/heads/syrus/direct-4649",
      tree_sha: "tree123",
      published_at: Time.current
    )

    expect { workflow.destroy }.to change(described_class, :count).by(-1)
    expect(workflow).to be_destroyed
    expect(Step.exists?(step.id)).to be(false)
  end
end
