require "rails_helper"

RSpec.describe RefMovementActions::SubmitBranchUpstream do
  let(:user) { Factories.user }
  let(:canonical) { Factories.repository(user: user, default_branch: "main") }
  let(:fork_repo) { Factories.repository(user: user, default_branch: "main", upstream_repository: canonical) }
  let(:config) do
    SyrusYml::DeliveryRefMovementAction.new(
      name: "submit_branch_upstream", enabled: true, source: nil, target: nil, mode: "manual_pr", grade_phases: []
    )
  end

  before do
    allow(StepDispatcher).to receive(:start_workflow)
  end

  def stub_policy(source_branch: "develop", target_branch: "main", enabled: true)
    allow_any_instance_of(DeliveryPolicy).to receive(:upstream_export_enabled?).and_return(enabled)
    allow_any_instance_of(DeliveryPolicy).to receive(:job_landing_branch).with(no_args).and_return(source_branch)
    allow_any_instance_of(DeliveryPolicy).to receive(:upstream_export_target_branch).with(no_args).and_return(target_branch)
    allow_any_instance_of(DeliveryPolicy).to receive(:ref_movement_action_config).with("submit_branch_upstream").and_return(config)
  end

  describe "#available?" do
    it "requires the repository to have an in-instance upstream_repository" do
      standalone_repo = Factories.repository(user: user)

      available, reason = described_class.new.available?(repository: standalone_repo)

      expect(available).to be(false)
      expect(reason).to include("no in-instance upstream_repository")
    end

    it "requires upstream_export to be enabled" do
      stub_policy(enabled: false)

      available, reason = described_class.new.available?(repository: fork_repo)

      expect(available).to be(false)
      expect(reason).to include("upstream_export is not enabled")
    end

    it "is available once every guard passes" do
      stub_policy

      available, reason = described_class.new.available?(repository: fork_repo)

      expect(available).to be(true)
      expect(reason).to be_nil
    end

    it "is blocked while a matching export is already in flight" do
      stub_policy(source_branch: "develop")
      pending_job = Job.create!(user: user, repository: fork_repo, kind: "direct", issue_number: nil, branch_name: "develop", issue_title: "x", issue_body: "x", priority: "high")
      Workflow.create!(job: pending_job, trigger_kind: "upstream_export", state: "queued")

      available, reason = described_class.new.available?(repository: fork_repo)

      expect(available).to be(false)
      expect(reason).to include("already in flight")
    end
  end

  describe "#dispatch! (via RefMovementAction.dispatch!)" do
    it "creates a synthetic anchor Job and dispatches an upstream_export workflow" do
      stub_policy(source_branch: "develop", target_branch: "main")

      expect { RefMovementAction.dispatch!(repository: fork_repo, actor: user, action: "submit_branch_upstream") }
        .to change(Job, :count).by(1)

      record = RefMovementAction.last
      expect(record).to be_dispatched
      expect(record.source_kind).to eq("branch")
      expect(record.source_ref).to eq("develop")
      expect(record.target_kind).to eq("upstream_intake")
      expect(record.target_ref).to eq("main")
      expect(record.target_repository).to eq(canonical)
      expect(record.target_inferred).to be(true)
      expect(record.job.branch_name).to eq("develop")
      expect(record.job.issue_number).to be_nil
      expect(record.workflow.trigger_kind).to eq("upstream_export")
    end

    it "uses an explicit source_branch/target_branch override and marks target_inferred false" do
      stub_policy(source_branch: "develop", target_branch: "main")

      record = RefMovementAction.dispatch!(
        repository: fork_repo, actor: user, action: "submit_branch_upstream",
        source: "feature/custom", target: "release/1.0"
      )

      expect(record).to be_dispatched
      expect(record.source_ref).to eq("feature/custom")
      expect(record.target_ref).to eq("release/1.0")
      expect(record.target_inferred).to be(false)
    end

    it "records a blocked row instead of raising when there is no upstream_repository" do
      standalone_repo = Factories.repository(user: user)
      allow_any_instance_of(DeliveryPolicy).to receive(:ref_movement_action_config).with("submit_branch_upstream").and_return(config)

      record = RefMovementAction.dispatch!(repository: standalone_repo, actor: user, action: "submit_branch_upstream")

      expect(record).to be_blocked
      expect(record.blocked_reason).to include("no in-instance upstream_repository")
      expect(record.job).to be_nil
    end
  end
end
