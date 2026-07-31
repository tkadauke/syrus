require "rails_helper"

RSpec.describe ReconcileJobStatesJob do
  let(:job) do
    j = Factories.job
    # Strip the factory-created initial Workflow + Run so each spec
    # starts with a clean Job. Specs build whatever workflows they
    # need explicitly via build_workflow.
    j.runs.destroy_all
    j.workflows.destroy_all
    j
  end

  def build_workflow(state:, trigger_kind: "pr_comment", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
    Workflow.create!(
      job: job, trigger_kind: trigger_kind, state: state,
      started_at: started_at,
      finished_at: %w[ succeeded failed cancelled ].include?(state) ? finished_at : nil
    )
  end

  def enable_unified_work_engine_reconciler!
    Feature.find_or_create_by!(slug: WorkEngine::Gate::FEATURE_SLUG) do |feature|
      feature.category = "Operations"
      feature.name = "Unified work-engine reconciler"
    end.update!(enabled: true)
  end

  it "delegates to the unified reconciler without mutating Jobs when that gate is enabled" do
    enable_unified_work_engine_reconciler!
    build_workflow(state: "succeeded")
    job.update!(state: "failed")

    expect {
      described_class.perform_now
    }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
      source: "ReconcileJobStatesJob",
      job_id: nil,
      workflow_id: nil,
      run_id: nil
    )

    expect(job.reload.state).to eq("failed")
  end

  describe "Job :failed with latest workflow :succeeded (Job 360 shape)" do
    it "lifts the Job through :queued to :implemented" do
      build_workflow(state: "succeeded")
      job.update!(state: "failed")

      expect { described_class.new.perform }
        .to change { job.reload.state }.from("failed").to("implemented")
    end
  end

  describe "Job :failed with latest workflow :running" do
    it "lifts the Job to :queued for retry-from-failed-step state" do
      build_workflow(state: "running", finished_at: nil)
      job.update!(state: "failed")

      expect { described_class.new.perform }
        .to change { job.reload.state }.from("failed").to("queued")
    end
  end

  describe "Job :failed with latest workflow :cancelled" do
    it "lifts the Job to :queued so the operator can decide what's next" do
      build_workflow(state: "cancelled")
      job.update!(state: "failed")

      expect { described_class.new.perform }
        .to change { job.reload.state }.from("failed").to("queued")
    end
  end

  describe "Job :implemented with latest workflow :running" do
    it "lifts the Job back to :running (workflow reopened post-success)" do
      build_workflow(state: "running", finished_at: nil)
      job.update!(state: "implemented")

      expect { described_class.new.perform }
        .to change { job.reload.state }.from("implemented").to("running")
    end
  end

  describe "Job :running with latest workflow :succeeded" do
    it "drops the Job to :implemented when no active work remains" do
      build_workflow(state: "succeeded")
      job.update!(state: "running")

      expect { described_class.new.perform }
        .to change { job.reload.state }.from("running").to("implemented")
    end

    it "leaves the Job alone when an active workflow exists (don't race brand-new work)" do
      build_workflow(state: "succeeded")
      build_workflow(state: "running", finished_at: nil)
      job.update!(state: "running")

      # latest workflow is the :running one, so no reconciliation needed
      expect { described_class.new.perform }
        .not_to change { job.reload.state }
    end
  end

  describe "Job :running with latest workflow :failed" do
    it "drops the Job to :failed only when no other active work exists" do
      build_workflow(state: "failed")
      job.update!(state: "running")

      expect { described_class.new.perform }
        .to change { job.reload.state }.from("running").to("failed")
    end
  end

  describe "Job :running with latest workflow :cancelled" do
    it "drops the Job to :failed when no active work remains" do
      build_workflow(state: "cancelled")
      job.update!(state: "running")

      expect { described_class.new.perform }
        .to change { job.reload.state }.from("running").to("failed")
    end

    it "leaves the Job alone when another active workflow exists" do
      build_workflow(state: "cancelled", started_at: 10.minutes.ago, finished_at: 9.minutes.ago)
      build_workflow(state: "running", started_at: 1.minute.ago, finished_at: nil)
      job.update!(state: "running")

      expect { described_class.new.perform }
        .not_to change { job.reload.state }
    end
  end

  describe "Job already consistent with latest workflow" do
    it "is a no-op when Job :implemented matches workflow :succeeded" do
      build_workflow(state: "succeeded")
      job.update!(state: "implemented")

      expect { described_class.new.perform }
        .not_to change { job.reload.state }
    end

    it "is a no-op when Job :running matches workflow :running" do
      build_workflow(state: "running", finished_at: nil)
      job.update!(state: "running")

      expect { described_class.new.perform }
        .not_to change { job.reload.state }
    end
  end

  describe "main_grader anchor jobs" do
    def main_grader_job(state:)
      user = Factories.user
      repository = Factories.repository(user: user)
      Job.create!(
        user: user,
        owner_user: user,
        repository: repository,
        kind: "main_grader",
        issue_title: "main_grader:abc123",
        issue_number: nil,
        state: state
      )
    end

    it "closes an implemented main_grader Job" do
      main_grader = main_grader_job(state: "implemented")

      expect { described_class.new.perform }
        .to change { main_grader.reload.state }.from("implemented").to("closed")

      expect(main_grader.closure_reason).to eq(Job::MAIN_GRADER_CLOSURE_REASON)
    end

    it "closes a main_grader Job whose workflow already finished" do
      main_grader = main_grader_job(state: "running")
      workflow = Workflow.create!(
        job: main_grader,
        trigger_kind: "main_grader",
        state: "succeeded",
        started_at: 5.minutes.ago,
        finished_at: 1.minute.ago
      )
      step = Step.create!(workflow: workflow, kind: "grader_collect", position: 0, state: "succeeded")
      run = Run.create!(job: main_grader, step: step, trigger_kind: "main_grader", state: "succeeded")

      expect { described_class.new.perform }
        .to change { main_grader.reload.state }.from("running").to("closed")

      expect(main_grader.closure_reason).to eq(Job::MAIN_GRADER_CLOSURE_REASON)
      expect(run.job_logs.where(kind: "system").pluck(:chunk))
        .to include(match(/\[reconciler\] Closed completed main grader Job/))
    end

    it "leaves an active main_grader Job alone" do
      main_grader = main_grader_job(state: "running")
      Workflow.create!(
        job: main_grader,
        trigger_kind: "main_grader",
        state: "running",
        started_at: 1.minute.ago,
        finished_at: nil
      )

      expect { described_class.new.perform }
        .not_to change { main_grader.reload.state }
    end
  end

  describe "out-of-scope Job states" do
    %w[ triaging blocked_by_epic approved landing closed ].each do |state|
      it "leaves :#{state} Jobs alone (owned by other code paths)" do
        build_workflow(state: "running", finished_at: nil)
        # Use update_columns to skip AASM guards — these states may
        # have their own entry preconditions we don't care about here.
        job.update_columns(state: state)

        expect { described_class.new.perform }
          .not_to change { job.reload.state }
      end
    end
  end

  describe "Job with no workflow" do
    it "leaves the Job alone — nothing to reconcile against" do
      job.workflows.destroy_all
      job.update!(state: "queued")

      expect { described_class.new.perform }
        .not_to change { job.reload.state }
    end
  end

  describe "error isolation" do
    it "logs and continues when one Job's reconcile raises" do
      build_workflow(state: "succeeded")
      job.update!(state: "failed")

      allow_any_instance_of(Job).to receive(:retry_after_failure!).and_raise(StandardError, "kaboom")

      expect(Rails.logger).to receive(:warn).with(/#{job.slug} reconcile failed/)
      expect { described_class.new.perform }.not_to raise_error
    end
  end

  describe "audit log" do
    it "appends a system JobLog line on the latest Run when a reconciliation runs" do
      wf = build_workflow(state: "succeeded")
      step = Step.create!(workflow: wf, kind: "implement", position: 0, state: "succeeded")
      Run.create!(job: job, step: step, trigger_kind: "pr_comment", state: "succeeded")
      job.update!(state: "failed")

      described_class.new.perform

      latest_run = job.runs.order(:created_at).last
      expect(latest_run.job_logs.where(kind: "system").pluck(:chunk))
        .to include(match(/\[reconciler\] Job state failed → implemented/))
    end
  end
end
