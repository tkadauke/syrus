require "rails_helper"

RSpec.describe HotfixSyncDispatcher do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }

  before do
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_source_branch: "main", hotfix_sync_target_branch: "develop")
    )
    # Same seam PromotionDispatcher's spec uses: exercise the
    # instantiate/dispatch wiring without depending on WorkUnits::Launcher's
    # Scheduler gates.
    allow(StepDispatcher).to receive(:start_workflow)
  end

  describe ".call!" do
    it "creates a synthetic direct anchor Job with no GitHub issue" do
      described_class.call!(repository: repository)

      job = Job.order(:id).last
      expect(job.kind).to eq("direct")
      expect(job.issue_number).to be_nil
      expect(job.repository).to eq(repository)
      expect(job.user).to eq(user)
      expect(job.issue_title).to eq("Sync main into develop")
    end

    it "dispatches a Workflows::HotfixSync workflow seeded with the resolved refs" do
      described_class.call!(repository: repository)

      job = Job.order(:id).last
      workflow = job.workflows.last
      expect(workflow.trigger_kind).to eq("hotfix_sync")
      expect(workflow.artifact("hotfix_sync_source_branch")).to eq("main")
      expect(workflow.artifact("hotfix_sync_target_branch")).to eq("develop")
    end

    it "starts the workflow via StepDispatcher" do
      described_class.call!(repository: repository)

      job = Job.order(:id).last
      workflow = job.workflows.last
      expect(StepDispatcher).to have_received(:start_workflow).with(workflow)
    end

    it "honors explicit source_branch/target_branch overrides instead of resolving from DeliveryPolicy" do
      described_class.call!(repository: repository, source_branch: "release/1.0", target_branch: "develop")

      workflow = Job.order(:id).last.workflows.last
      expect(workflow.artifact("hotfix_sync_source_branch")).to eq("release/1.0")
    end

    it "defaults the anchor Job's user to the repository owner when no user is given" do
      described_class.call!(repository: repository)

      expect(Job.order(:id).last.user).to eq(repository.user)
    end
  end

  describe ".pending_for?" do
    it "is false when the repository has no open hotfix_sync workflow" do
      expect(described_class.pending_for?(repository)).to be(false)
    end

    it "is true once a hotfix_sync workflow has been dispatched and is still open" do
      described_class.call!(repository: repository)

      expect(described_class.pending_for?(repository)).to be(true)
    end

    it "is false again once the anchor Job closes" do
      described_class.call!(repository: repository)
      Job.order(:id).last.close_with_reason!("hotfix_sync_landed")

      expect(described_class.pending_for?(repository)).to be(false)
    end
  end
end
