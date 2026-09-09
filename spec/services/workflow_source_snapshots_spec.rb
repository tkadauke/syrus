require "rails_helper"

RSpec.describe WorkflowSourceSnapshots, :ci_only do
  let(:job) { Factories.job_record(state: "running") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }
  let(:step) { Step.create!(workflow: workflow, kind: "implement", position: 0, state: "succeeded") }

  describe ".record!" do
    it "persists checkout identity for a workflow source" do
      snapshot = described_class.record!(
        workflow: workflow,
        creator_step: step,
        source_sha: "abc123",
        source_ref: "refs/heads/syrus/direct-4649",
        tree_sha: "tree123",
        published_at: Time.zone.parse("2026-09-09 12:34:56 UTC")
      )

      expect(snapshot).to have_attributes(
        workflow: workflow,
        creator_step: step,
        source_sha: "abc123",
        source_ref: "refs/heads/syrus/direct-4649",
        tree_sha: "tree123",
        fingerprint: nil,
        published_at: Time.zone.parse("2026-09-09 12:34:56 UTC")
      )
    end
  end

  describe ".current_for" do
    it "returns the newest published snapshot for the workflow" do
      older = described_class.record!(
        workflow: workflow,
        creator_step: step,
        source_sha: "old",
        source_ref: "refs/heads/old",
        fingerprint: "old-fingerprint",
        published_at: 2.hours.ago
      )
      newer = described_class.record!(
        workflow: workflow,
        creator_step: step,
        source_sha: "new",
        source_ref: "refs/heads/new",
        fingerprint: "new-fingerprint",
        published_at: 1.hour.ago
      )

      expect(described_class.current_for(workflow)).to eq(newer)
      expect(described_class.current_for(workflow)).not_to eq(older)
    end
  end

  describe ".require_current!" do
    it "raises infrastructure state for missing metadata" do
      expect {
        described_class.require_current!(workflow)
      }.to raise_error(described_class::InfrastructureStateError, /metadata missing/)
    end

    it "raises infrastructure state for mismatched metadata" do
      described_class.record!(
        workflow: workflow,
        creator_step: step,
        source_sha: "abc123",
        source_ref: "refs/heads/syrus/direct-4649",
        tree_sha: "tree123"
      )

      expect {
        described_class.require_current!(workflow, source_sha: "def456", tree_sha: "tree123")
      }.to raise_error(described_class::InfrastructureStateError, /metadata mismatch: source_sha/)
    end

    it "returns the snapshot when requested identity matches" do
      snapshot = described_class.record!(
        workflow: workflow,
        creator_step: step,
        source_sha: "abc123",
        source_ref: "refs/heads/syrus/direct-4649",
        tree_sha: "tree123"
      )

      expect(described_class.require_current!(workflow, source_sha: "abc123", tree_sha: "tree123")).to eq(snapshot)
    end
  end
end
