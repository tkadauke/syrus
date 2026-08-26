require "rails_helper"

RSpec.describe RefMovementActions::SendJobUpstream do
  let(:user) { Factories.user }
  let(:canonical) { Factories.repository(user: user, default_branch: "main") }
  let(:fork_repo) { Factories.repository(user: user, default_branch: "main", upstream_repository: canonical) }
  let(:job) { Factories.job_record(user: user, repository: fork_repo, issue_number: 1, state: "approved", branch_name: "syrus/issue-1") }
  let(:config) { SyrusYml::DeliveryRefMovementAction.new(name: "send_job_upstream", enabled: true, source: nil, target: nil, mode: "manual_pr", grade_phases: [ "promotion" ]) }

  before do
    allow(StepDispatcher).to receive(:start_workflow)
  end

  def stub_upstream_export_target_branch(branch: "main")
    allow_any_instance_of(DeliveryPolicy).to receive(:upstream_export_target_branch).and_return(branch)
    allow_any_instance_of(DeliveryPolicy).to receive(:upstream_export_enabled?).and_return(true)
    allow_any_instance_of(DeliveryPolicy).to receive(:ref_movement_action_config).with("send_job_upstream").and_return(config)
  end

  describe "#available?" do
    it "requires a job" do
      available, reason = described_class.new.available?(repository: fork_repo, job: nil)

      expect(available).to be(false)
      expect(reason).to include("job is required")
    end

    it "requires upstream_export to be enabled" do
      allow_any_instance_of(DeliveryPolicy).to receive(:upstream_export_enabled?).and_return(false)

      available, reason = described_class.new.available?(repository: fork_repo, job: job)

      expect(available).to be(false)
      expect(reason).to include("upstream_export is not enabled")
    end

    it "requires the repository to have an in-instance upstream_repository" do
      standalone_repo = Factories.repository(user: user)
      standalone_job = Factories.job_record(user: user, repository: standalone_repo, issue_number: 2, state: "approved", branch_name: "syrus/issue-2")

      available, reason = described_class.new.available?(repository: standalone_repo, job: standalone_job)

      expect(available).to be(false)
      expect(reason).to include("no in-instance upstream_repository")
    end

    it "is available once every guard passes" do
      stub_upstream_export_target_branch

      available, reason = described_class.new.available?(repository: fork_repo, job: job)

      expect(available).to be(true)
      expect(reason).to be_nil
    end
  end

  describe "#dispatch! (via RefMovementAction.dispatch!)" do
    it "dispatches an upstream_export workflow and records source/target on the audit row" do
      stub_upstream_export_target_branch(branch: "develop")

      record = RefMovementAction.dispatch!(repository: fork_repo, actor: user, action: "send_job_upstream", source: job)

      expect(record).to be_dispatched
      expect(record.job).to eq(job)
      expect(record.source_kind).to eq("job_branch")
      expect(record.source_ref).to eq("syrus/issue-1")
      expect(record.target_kind).to eq("upstream_intake")
      expect(record.target_ref).to eq("develop")
      expect(record.target_repository).to eq(canonical)
      expect(record.target_inferred).to be(true)
      expect(record.mode).to eq("manual_pr")
      expect(record.grade_phases).to eq([ "promotion" ])
      expect(record.workflow).to be_present
      expect(record.workflow.trigger_kind).to eq("upstream_export")
    end

    it "records a blocked row instead of raising when the job is not eligible" do
      stub_upstream_export_target_branch
      job.update_columns(state: "closed", closure_reason: "pr_merged")

      record = RefMovementAction.dispatch!(repository: fork_repo, actor: user, action: "send_job_upstream", source: job)

      expect(record).to be_blocked
      expect(record.blocked_reason).to include("not open")
      expect(record.workflow).to be_nil
    end

    it "raises ArgumentError when source is not a Job" do
      allow(DeliveryPolicy).to receive(:for).with(repository: fork_repo).and_return(
        instance_double(DeliveryPolicy, ref_movement_action_config: config)
      )

      expect {
        RefMovementAction.dispatch!(repository: fork_repo, actor: user, action: "send_job_upstream", source: "not-a-job")
      }.to raise_error(ArgumentError, /requires a Job/)
    end
  end
end
