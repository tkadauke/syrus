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
      source_ref: "refs/heads/syrus/direct-749",
      published_at: Time.current
    )

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:base]).to include("tree_sha or fingerprint must be present")
  end

  describe "#attach_prepared_workspace_archive" do
    def snapshot_for(source_sha:, fingerprint: nil)
      described_class.create!(
        workflow: workflow,
        creator_step: step,
        source_sha: source_sha,
        source_ref: "refs/heads/syrus/source-snapshots/#{source_sha}",
        tree_sha: "tree-#{source_sha}",
        prepare_fingerprint: fingerprint,
        published_at: Time.current
      )
    end

    def blob_for(data)
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(data),
        filename: "prepared.tar.gz",
        content_type: "application/gzip"
      )
    end

    # Regression: grader fanout puts several graders on one snapshot across
    # several workers. Each independently resolved the same reusable blob, saw
    # the snapshot unattached, and attached it -- and the attachment
    # uniqueness index rejected whichever insert landed second with
    # RecordNotUnique. Production classified that as an unretryable
    # application error and failed a Run that had done nothing wrong.
    it "treats a concurrent attach of the same blob as success" do
      snapshot = snapshot_for(source_sha: "abc123")
      blob = blob_for("archive")

      # The other worker resolved the same reusable blob and its INSERT landed
      # first, so this one's insert hits the attachment uniqueness index. This
      # is the exact production shape: same snapshot, same blob, two workers.
      allow(snapshot.prepared_workspace_archive).to receive(:attach) do
        ActiveStorage::Attachment.create!(record: snapshot, name: "prepared_workspace_archive", blob: blob)
        raise ActiveRecord::RecordNotUnique,
          "Mysql2::Error: Duplicate entry 'WorkflowSourceSnapshot-#{snapshot.id}-prepared_workspace_archive-#{blob.id}'"
      end

      expect { expect(snapshot.attach_prepared_workspace_archive(blob)).to be(true) }.not_to raise_error
      expect(snapshot.reload.prepared_workspace_archive.blob.id).to eq(blob.id)
    end

    it "reports false rather than raising when a different blob wins the race" do
      snapshot = snapshot_for(source_sha: "def456")
      winner = blob_for("winner")
      loser = blob_for("loser")

      allow(snapshot.prepared_workspace_archive).to receive(:attach) do
        ActiveStorage::Attachment.create!(record: snapshot, name: "prepared_workspace_archive", blob: winner)
        raise ActiveRecord::RecordNotUnique, "Duplicate entry"
      end

      expect(snapshot.attach_prepared_workspace_archive(loser)).to be(false)
      expect(snapshot.reload.prepared_workspace_archive.blob.id).to eq(winner.id)
    end
  end

  it "requires a creator step" do
    snapshot = described_class.new(
      workflow: workflow,
      source_sha: "abc123",
      source_ref: "refs/heads/syrus/direct-749",
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
      source_ref: "refs/heads/syrus/direct-749",
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
      source_ref: "refs/heads/syrus/direct-749",
      tree_sha: "tree123",
      published_at: Time.current
    )

    expect { workflow.destroy }.to change(described_class, :count).by(-1)
    expect(workflow).to be_destroyed
    expect(Step.exists?(step.id)).to be(false)
  end
end
