require "rails_helper"

RSpec.describe UpstreamExportDispatcher do
  let(:user) { Factories.user }
  let(:canonical) { Factories.repository(user: user, default_branch: "main") }
  let(:fork_repo) { Factories.repository(user: user, default_branch: "main", upstream_repository: canonical) }
  let(:job) { Factories.job_record(user: user, repository: fork_repo, issue_number: 1, state: "approved", branch_name: "syrus/issue-1") }

  before do
    allow(StepDispatcher).to receive(:start_workflow)
  end

  def stub_policy(export_after_approval:, target_branch: "main", for_job: job, for_repo: fork_repo, upstream_export_enabled: true)
    allow(DeliveryPolicy).to receive(:for).with(repository: for_repo, job: for_job).and_return(
      instance_double(
        DeliveryPolicy,
        export_upstream_after_local_approval?: export_after_approval,
        upstream_export_enabled?: upstream_export_enabled,
        upstream_export_target_branch: target_branch
      )
    )
  end

  describe ".call!" do
    it "dispatches an upstream_export workflow onto the existing job when eligible" do
      stub_policy(export_after_approval: true)

      described_class.call!(job)

      workflow = job.workflows.order(:id).last
      expect(workflow).to be_present
      expect(workflow.trigger_kind).to eq("upstream_export")
      expect(workflow.job).to eq(job)
      expect(StepDispatcher).to have_received(:start_workflow).with(workflow)
    end

    it "does not create a synthetic anchor job — it dispatches onto the job passed in" do
      stub_policy(export_after_approval: true)

      expect { described_class.call!(job) }.not_to change(Job, :count)
    end

    it "does not dispatch when upstream export is not configured to fire after local approval" do
      stub_policy(export_after_approval: false)

      described_class.call!(job)

      expect(job.workflows.where(trigger_kind: "upstream_export")).to be_empty
    end

    it "does not dispatch when the job's repository has no in-instance upstream_repository" do
      standalone_repo = Factories.repository(user: user)
      standalone_job = Factories.job_record(user: user, repository: standalone_repo, issue_number: 2, state: "approved", branch_name: "syrus/issue-2")

      described_class.call!(standalone_job)

      expect(standalone_job.workflows).to be_empty
    end

    it "does not dispatch when the job is not open" do
      stub_policy(export_after_approval: true)
      job.update_columns(state: "closed", closure_reason: "pr_merged")

      described_class.call!(job)

      expect(job.workflows.where(trigger_kind: "upstream_export")).to be_empty
    end

    it "does not dispatch when the job has no branch yet" do
      stub_policy(export_after_approval: true)
      job.update_columns(branch_name: nil)

      described_class.call!(job)

      expect(job.workflows.where(trigger_kind: "upstream_export")).to be_empty
    end

    it "is idempotent once a JobPrLink already recorded a published PR number" do
      stub_policy(export_after_approval: true)
      JobPrLink.record!(job: job, role: JobPrLink::ROLE_UPSTREAM_EXPORT, pr_number: 55)

      described_class.call!(job)

      expect(job.workflows.where(trigger_kind: "upstream_export")).to be_empty
    end

    it "does not dispatch a second workflow while one is already queued or running" do
      stub_policy(export_after_approval: true)
      Workflow.create!(job: job, trigger_kind: "upstream_export", state: "queued")

      expect { described_class.call!(job) }.not_to change { job.workflows.count }
    end

    it "dispatches again once a prior upstream_export workflow has already finished without recording a PR link" do
      stub_policy(export_after_approval: true)
      Workflow.create!(job: job, trigger_kind: "upstream_export", state: "failed", finished_at: Time.current)

      described_class.call!(job)

      expect(job.workflows.where(trigger_kind: "upstream_export", state: "queued")).to be_present
    end

    describe "explicit: true (Story 11's send_job_upstream ref-movement action)" do
      it "dispatches even when after_local_approval is false, as long as upstream_export is enabled" do
        stub_policy(export_after_approval: false, upstream_export_enabled: true)

        described_class.call!(job, explicit: true)

        workflow = job.workflows.order(:id).last
        expect(workflow).to be_present
        expect(workflow.trigger_kind).to eq("upstream_export")
      end

      it "still does not dispatch when upstream_export itself is disabled" do
        stub_policy(export_after_approval: false, upstream_export_enabled: false)

        described_class.call!(job, explicit: true)

        expect(job.workflows.where(trigger_kind: "upstream_export")).to be_empty
      end

      it "does not affect the default (non-explicit) auto-trigger gate" do
        stub_policy(export_after_approval: false, upstream_export_enabled: true)

        described_class.call!(job)

        expect(job.workflows.where(trigger_kind: "upstream_export")).to be_empty
      end
    end
  end
end
