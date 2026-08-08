require "rails_helper"

RSpec.describe Workflow do
  include ActiveJob::TestHelper

  let(:job) { Factories.job }

  def build_wf(**overrides)
    described_class.new({ job: job, trigger_kind: "initial" }.merge(overrides))
  end

  describe "validations" do
    it "is valid with a known trigger_kind" do
      expect(build_wf(trigger_kind: "initial")).to be_valid
    end

    it "rejects unknown trigger_kind" do
      expect(build_wf(trigger_kind: "rumour")).not_to be_valid
    end

    it "rejects unknown agent_provider" do
      expect(build_wf(agent_provider: "oracle")).not_to be_valid
    end

    it "requires a job" do
      expect(build_wf(job: nil)).not_to be_valid
    end

    it "rejects new workflows for closed jobs" do
      job.update_columns(state: "closed", finished_at: Time.current, closure_reason: "operator_cancelled")

      workflow = build_wf

      expect(workflow).not_to be_valid
      expect(workflow.errors[:job]).to include("is closed")
    end

    it "defaults the execution owner from the job" do
      workflow = described_class.create!(job: job, trigger_kind: "initial")

      expect(workflow.user).to eq(job.user)
    end

    it "keeps retry runs on the workflow pinned provider" do
      workflow = described_class.create!(job: job, trigger_kind: "initial", agent_provider: "claude")
      step = Step.create!(workflow: workflow, kind: "implement", position: 0, state: "failed")
      job.update!(job_provider_setting: "codex")

      run = StepDispatcher.create_run_and_enqueue(step, workflow)

      expect(run.agent_provider).to eq("claude")
    end

    it "rejects an execution owner from another user's job" do
      other_user = Factories.user
      workflow = build_wf(user: other_user)

      expect(workflow).not_to be_valid
      expect(workflow.errors[:user]).to include("must match the Job owner")
    end
  end

  describe "AASM state machine" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    it "starts queued" do
      expect(wf.state).to eq("queued")
    end

    it "transitions queued → running with started_at" do
      freeze_time do
        wf.start!
        wf.save!
        expect(wf).to be_running
        expect(wf.started_at).to eq(Time.current)
      end
    end

    it "transitions running → succeeded with finished_at" do
      wf.start!
      freeze_time do
        wf.succeed!
        wf.save!
        expect(wf).to be_succeeded
        expect(wf.finished_at).to eq(Time.current)
      end
    end

    it "transitions running → failed with finished_at" do
      wf.start!
      wf.fail!
      wf.save!
      expect(wf).to be_failed
      expect(wf.finished_at).to be_present
    end

    it "cancels older active retry workflows after a newer workflow publishes the same PR branch" do
      job.update!(state: "implemented", pr_number: 77, branch_name: "syrus/direct-#{job.id}")
      older = described_class.create!(
        job: job,
        trigger_kind: "retry",
        state: "queued",
        artifacts: { "publication_branch" => job.branch_name }
      )
      Step.create!(workflow: older, kind: "implement", position: 0)
      newer = described_class.create!(
        job: job,
        trigger_kind: "retry",
        state: "running",
        started_at: 1.minute.ago,
        artifacts: { "publication_branch" => job.branch_name }
      )
      allow(WorkflowWorkspace).to receive(:cleanup_for)

      newer.succeed!
      newer.save!

      expect(older.reload).to be_cancelled
      expect(older.artifact("retry_cancelled_reason")).to eq("superseded")
      expect(older.artifact("superseded_by_workflow_id")).to eq(newer.id)
    end
  end

  describe "feedback addressed watermark" do
    it "records the newest feedback comment time when a pr_comment workflow succeeds" do
      older = Time.parse("2026-05-02 05:00:00 UTC")
      newer = Time.parse("2026-05-02 05:05:00 UTC")
      wf = described_class.create!(
        job: job,
        trigger_kind: "pr_comment",
        artifacts: {
          "pr_comments" => [
            { "body" => "first", "created_at" => older.iso8601 },
            { "body" => "second", "created_at" => newer.iso8601 }
          ]
        }
      )

      wf.start!
      wf.succeed!
      wf.save!

      expect(job.reload.last_feedback_addressed_at.utc).to be_within(1.second).of(newer)
    end

    it "does not move the addressed watermark for failed pr_comment workflows" do
      wf = described_class.create!(
        job: job,
        trigger_kind: "pr_comment",
        artifacts: {
          "pr_comments" => [
            { "body" => "still broken", "created_at" => Time.parse("2026-05-02 05:00:00 UTC").iso8601 }
          ]
        }
      )

      wf.start!
      wf.fail!
      wf.save!

      expect(job.reload.last_feedback_addressed_at).to be_nil
    end
  end

  describe "#cancel cascades to active descendants" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "ci_failure") }

    it "cancels every still-queued Step and any active Runs on them" do
      done_step    = Step.create!(workflow: wf, kind: "prepare",         position: 0, state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      stuck_step_1 = Step.create!(workflow: wf, kind: "summarize_amend", position: 1)  # queued
      stuck_step_2 = Step.create!(workflow: wf, kind: "push",            position: 2)  # queued

      done_run     = Run.create!(job: job, step: done_step, trigger_kind: "ci_failure", state: "succeeded")
      stuck_run    = Run.create!(job: job, step: stuck_step_1, trigger_kind: "ci_failure")  # queued

      wf.start!
      wf.cancel!
      wf.save!

      expect(wf).to be_cancelled
      expect(stuck_step_1.reload.state).to eq("cancelled")
      expect(stuck_step_2.reload.state).to eq("cancelled")
      expect(stuck_run.reload.state).to    eq("cancelled")

      # Already-terminal records are left alone.
      expect(done_step.reload.state).to eq("succeeded")
      expect(done_run.reload.state).to  eq("succeeded")
    end

    it "is idempotent — cancelling again does not crash on already-cancelled descendants" do
      step = Step.create!(workflow: wf, kind: "summarize_amend", position: 0, state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
      wf.start!
      wf.cancel!
      wf.save!
      expect(step.reload.state).to eq("cancelled")
    end
  end

  describe "#cleanup_workspace!" do
    it "defers cleanup while a descendant Run is still active" do
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)
      step = Step.create!(workflow: wf, kind: "implement", position: 0, state: "running", started_at: 1.minute.ago)
      step.runs.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        started_at: 1.minute.ago,
        last_heartbeat_at: Time.current
      )
      allow(WorkflowWorkspace).to receive(:cleanup_for)

      expect(wf.cleanup_workspace!).to eq(false)

      expect(WorkflowWorkspace).not_to have_received(:cleanup_for)
      expect(wf.reload.cleaned_up_at).to be_nil
    end

    it "allows cleanup of a terminal workflow with only queued retry-tail Steps" do
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
      Step.create!(workflow: wf, kind: "summarize", position: 0)
      allow(WorkflowWorkspace).to receive(:cleanup_for) do |workflow|
        workflow.update_columns(cleaned_up_at: Time.current)
      end

      expect(wf.cleanup_workspace!).to eq(true)

      expect(WorkflowWorkspace).to have_received(:cleanup_for).with(wf)
      expect(wf.reload.cleaned_up_at).to be_present
    end
  end

  describe "Job state propagation (Phase 2)" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }

    it "drives :queued → :running on workflow.start! for non-auto_merge workflows" do
      wf = described_class.create!(job: job, trigger_kind: "initial")

      expect { wf.start!; wf.save! }
        .to change { job.reload.state }.from("queued").to("running")
    end

    it "drives :implemented → :running on workflow.start! for follow-up (pr_comment) workflows" do
      job.update!(state: "implemented")
      wf = described_class.create!(job: job, trigger_kind: "pr_comment")

      expect { wf.start!; wf.save! }
        .to change { job.reload.state }.from("implemented").to("running")
    end

    it "leaves Job state untouched on workflow.start! for auto_merge workflows" do
      job.update!(state: "approved")
      job.start_landing!; job.save!
      wf = described_class.create!(job: job, trigger_kind: "auto_merge")

      expect { wf.start!; wf.save! }
        .not_to change { job.reload.state }

      expect(job.reload.state).to eq("landing")
    end

    it "drives :running → :failed on workflow.fail! for non-auto_merge workflows" do
      job.update!(state: "running")
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)

      expect { wf.fail!; wf.save! }
        .to change { job.reload.state }.from("running").to("failed")
    end

    it "drives :running → :failed on workflow.cancel! for non-auto_merge workflows" do
      job.update!(state: "running")
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)

      expect { wf.cancel!; wf.save! }
        .to change { job.reload.state }.from("running").to("failed")
    end

    it "restores :triaging → :implemented when a rebase workflow is cancelled with 0 runs" do
      job.update!(state: "triaging")
      wf = described_class.create!(job: job, trigger_kind: "rebase")

      expect { wf.cancel!; wf.save! }
        .to change { job.reload.state }.from("triaging").to("implemented")
    end

    it "restores :triaging → :implemented when a stack_rebase workflow is cancelled with 0 runs" do
      job.update!(state: "triaging")
      wf = described_class.create!(job: job, trigger_kind: "stack_rebase")

      expect { wf.cancel!; wf.save! }
        .to change { job.reload.state }.from("triaging").to("implemented")
    end

    it "does not change job state when a rebase workflow with runs is cancelled" do
      job.update!(state: "triaging")
      wf = described_class.create!(job: job, trigger_kind: "rebase", state: "running", started_at: 1.minute.ago)
      step = Step.create!(workflow: wf, kind: "auto_rebase", position: 0, state: "running", started_at: 1.minute.ago)
      Run.create!(job: job, step: step, trigger_kind: "rebase", state: "running")

      expect { wf.cancel!; wf.save! }
        .not_to change { job.reload.state }

      expect(job.reload.state).to eq("triaging")
    end

    it "does not change job state when a rebase workflow is cancelled and job is not in triaging" do
      job.update!(state: "implemented")
      wf = described_class.create!(job: job, trigger_kind: "rebase")

      expect { wf.cancel!; wf.save! }
        .not_to change { job.reload.state }

      expect(job.reload.state).to eq("implemented")
    end

    it "does not let an older failed rebase workflow clobber a newer queued retry workflow" do
      job.update!(state: "running")
      old_rebase = described_class.create!(
        job: job,
        trigger_kind: "rebase",
        state: "running",
        started_at: 5.minutes.ago,
        created_at: 5.minutes.ago
      )
      retry_workflow = described_class.create!(
        job: job,
        trigger_kind: "retry",
        state: "queued",
        created_at: 1.minute.ago
      )

      expect { old_rebase.fail!; old_rebase.save! }
        .not_to change { job.reload.state }

      expect(job.reload.state).to eq("running")
      expect(job.latest_workflow).to eq(retry_workflow)
    end

    it "does not let an older failed rebase workflow clobber a newer running retry workflow" do
      job.update!(state: "running")
      old_rebase = described_class.create!(
        job: job,
        trigger_kind: "rebase",
        state: "running",
        started_at: 5.minutes.ago,
        created_at: 5.minutes.ago
      )
      retry_workflow = described_class.create!(
        job: job,
        trigger_kind: "retry",
        state: "running",
        started_at: 1.minute.ago,
        created_at: 1.minute.ago
      )

      expect { old_rebase.fail!; old_rebase.save! }
        .not_to change { job.reload.state }

      expect(job.reload.state).to eq("running")
      expect(job.latest_workflow).to eq(retry_workflow)
    end

    it "drives :running → :no_change_needed on workflow.fail! when the failing run has a NoChangesProduced diagnostic" do
      job.update!(state: "running")
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)
      step = Step.create!(workflow: wf, kind: "implement", position: 0, state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
      run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "failed")
      run.create_run_diagnostic!(error_class: "Steps::Base::NoChangesProduced", error_message: "agent produced no changes")

      expect { wf.fail!; wf.save! }
        .to change { job.reload.state }.from("running").to("no_change_needed")
    end

    it "drives :running → :failed (not :no_change_needed) for other failure types even with NoChangesProduced on a different run" do
      job.update!(state: "running")
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)
      step = Step.create!(workflow: wf, kind: "implement", position: 0, state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
      run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "failed")
      run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed", error_message: "some other error")

      expect { wf.fail!; wf.save! }
        .to change { job.reload.state }.from("running").to("failed")
    end

    it "does not propagate failure to Job on workflow.fail! for coding_handoff workflows" do
      job.update!(state: "running")
      wf = described_class.create!(job: job, trigger_kind: "coding_handoff", state: "running", started_at: 1.minute.ago)

      expect { wf.fail!; wf.save! }
        .not_to change { job.reload.state }

      expect(job.reload.state).to eq("running")
    end

    it "reverts Job to :coding (not :failed) on workflow.fail! for local_mode_handoff grader failures" do
      job.update!(state: "running")
      wf = described_class.create!(job: job, trigger_kind: "local_mode_handoff", state: "running", started_at: 1.minute.ago)
      Step.create!(workflow: wf, kind: "grader_collect", position: 0, iteration: 1, state: "failed")

      wf.fail!; wf.save!

      expect(job.reload.state).to eq("coding")
    end

    it "returns landing Jobs to implemented on workflow.fail! for auto_merge workflows" do
      job.update!(state: "landing")
      wf = described_class.create!(job: job, trigger_kind: "auto_merge", state: "running", started_at: 1.minute.ago)

      expect { wf.fail!; wf.save! }
        .to change { job.reload.state }.from("landing").to("implemented")
      expect(job.landing_failure_reason).to eq("auto_merge workflow failed")
    end

    it "pauses landing and keeps auto_merge Jobs approved when workflow failure is infrastructure-blocked" do
      job.update!(state: "implemented")
      job.approve!(via: "github_review")
      approved_at = job.approved_at
      job.start_landing!
      job.save!
      wf = Workflows::AutoMerge.instantiate(job: job)
      wf.update!(state: "running", started_at: 1.minute.ago)
      run = wf.steps.last.runs.create!(
        job: job,
        trigger_kind: "auto_merge",
        agent_provider: wf.agent_provider,
        state: "failed"
      )
      run.create_run_diagnostic!(
        error_class: "Errno::ENOSPC",
        error_message: "No space left on device @ rb_sysopen - /home/rails/.syrus/workflows/123"
      )

      expect { wf.fail!; wf.save! }
        .to change { job.reload.state }.from("landing").to("approved")

      expect(job.approved_at).to eq(approved_at)
      expect(job.landing_failure_reason).to include("No space left on device")
      expect(job.user.reload.landing_paused).to eq(true)
    end

    it "cleans unrepaired auto_merge workspaces on workflow.fail!" do
      job.update!(state: "landing")
      wf = Workflows::AutoMerge.instantiate(job: job)
      wf.update!(state: "running", started_at: 1.minute.ago)
      allow(WorkflowWorkspace).to receive(:cleanup_for)

      wf.fail!
      wf.save!

      expect(WorkflowWorkspace).to have_received(:cleanup_for).with(wf)
    end

    it "keeps auto_merge workspaces when a landing_fix step succeeded" do
      job.update!(state: "landing")
      wf = Workflows::AutoMerge.instantiate(job: job)
      wf.update!(state: "running", started_at: 1.minute.ago)
      Step.create!(workflow: wf, kind: "landing_fix", position: 99, state: "succeeded")
      allow(WorkflowWorkspace).to receive(:cleanup_for)

      wf.fail!
      wf.save!

      expect(WorkflowWorkspace).not_to have_received(:cleanup_for)
    end

    it "stops a job with runaway protection (not closed) when total workflows hit the limit" do
      guarded_job = Factories.job_record(user: job.user, repository: job.repository, state: "implemented")
      allow(NotificationService).to receive(:create_for)
      (Job::MAX_TOTAL_WORKFLOWS - 1).times do
        described_class.create!(job: guarded_job, trigger_kind: "retry", state: "succeeded", finished_at: 1.minute.ago)
      end

      workflow = described_class.create!(job: guarded_job, trigger_kind: "retry")

      expect(guarded_job.reload).to be_failed
      expect(guarded_job.runaway_protection).to eq("too_many_workflows")
      expect(guarded_job).not_to be_closed
      expect(workflow.reload).to be_cancelled
      expect(NotificationService).to have_received(:create_for).with(hash_including(job: guarded_job, kind: "job_failed"))
    end

    it "does not count workflows created before the latest job reopen toward the total runaway limit" do
      guarded_job = Factories.job_record(user: job.user, repository: job.repository, state: "implemented")
      allow(NotificationService).to receive(:create_for)
      (Job::MAX_TOTAL_WORKFLOWS - 1).times do
        described_class.create!(
          job: guarded_job,
          trigger_kind: "retry",
          state: "succeeded",
          created_at: 2.days.ago,
          finished_at: 2.days.ago
        )
      end
      guarded_job.close_with_reason!("too_many_workflows")
      travel_to 1.day.ago do
        guarded_job.reopen!
        guarded_job.save!
      end

      workflow = nil
      expect {
        workflow = described_class.create!(job: guarded_job.reload, trigger_kind: "retry")
      }.to change { guarded_job.reload.workflows.count }.by(1)

      expect(guarded_job.reload).not_to be_closed
      expect(workflow.reload).to be_queued
      expect(NotificationService).not_to have_received(:create_for)
    end

    it "applies runaway protection again on a reopened job when post-reopen workflows hit the limit" do
      guarded_job = Factories.job_record(user: job.user, repository: job.repository, state: "implemented")
      allow(NotificationService).to receive(:create_for)
      (Job::MAX_TOTAL_WORKFLOWS - 1).times do
        described_class.create!(
          job: guarded_job,
          trigger_kind: "retry",
          state: "succeeded",
          created_at: 2.days.ago,
          finished_at: 2.days.ago
        )
      end
      guarded_job.close_with_reason!("too_many_workflows")
      travel_to 1.day.ago do
        guarded_job.reopen!
        guarded_job.save!
      end
      (Job::MAX_TOTAL_WORKFLOWS - 1).times do
        described_class.create!(job: guarded_job.reload, trigger_kind: "retry", state: "succeeded")
      end

      workflow = described_class.create!(job: guarded_job.reload, trigger_kind: "retry")

      expect(guarded_job.reload).to be_failed
      expect(guarded_job.runaway_protection).to eq("too_many_workflows")
      expect(guarded_job).not_to be_closed
      expect(workflow.reload).to be_cancelled
      expect(NotificationService).to have_received(:create_for).with(hash_including(job: guarded_job, kind: "job_failed"))
    end

    it "stops a job with runaway protection after too many consecutive failed workflows" do
      guarded_job = Factories.job_record(user: job.user, repository: job.repository, state: "implemented")
      allow(NotificationService).to receive(:create_for)

      Job::MAX_CONSECUTIVE_FAILED_WORKFLOWS.times do
        workflow = described_class.create!(job: guarded_job, trigger_kind: "retry", state: "running", started_at: 1.minute.ago)
        workflow.fail!
        workflow.save!
      end

      expect(guarded_job.reload).to be_failed
      expect(guarded_job.runaway_protection).to eq("too_many_failed_workflows")
      expect(guarded_job).not_to be_closed
      expect(guarded_job.consecutive_failed_workflows_count).to eq(Job::MAX_CONSECUTIVE_FAILED_WORKFLOWS)
    end

    it "does not re-trigger the guard when runaway_protection is already set" do
      guarded_job = Factories.job_record(user: job.user, repository: job.repository, state: "failed")
      guarded_job.update_columns(runaway_protection: "too_many_workflows")
      allow(NotificationService).to receive(:create_for)

      # Creating another workflow should not fire the guard again
      described_class.create!(job: guarded_job, trigger_kind: "retry", state: "queued")

      expect(NotificationService).not_to have_received(:create_for)
    end

    it "does not count failed workflows across a successful workflow" do
      guarded_job = Factories.job_record(user: job.user, repository: job.repository, state: "implemented")
      allow(NotificationService).to receive(:create_for)

      (Job::MAX_CONSECUTIVE_FAILED_WORKFLOWS - 1).times do
        workflow = described_class.create!(job: guarded_job, trigger_kind: "retry", state: "running", started_at: 1.minute.ago)
        workflow.fail!
        workflow.save!
      end
      described_class.create!(job: guarded_job, trigger_kind: "retry", state: "succeeded", finished_at: 30.seconds.ago)
      (Job::MAX_CONSECUTIVE_FAILED_WORKFLOWS - 1).times do
        workflow = described_class.create!(job: guarded_job, trigger_kind: "retry", state: "running", started_at: 1.minute.ago)
        workflow.fail!
        workflow.save!
      end

      expect(guarded_job.reload).to be_open
      expect(guarded_job.consecutive_failed_workflows_count).to eq(Job::MAX_CONSECUTIVE_FAILED_WORKFLOWS - 1)
    end

    it "drives :running → :implemented on workflow.succeed! for follow-up workflows whose chain doesn't include pr_open" do
      job.update!(state: "running")
      wf = described_class.create!(job: job, trigger_kind: "pr_comment", state: "running", started_at: 1.minute.ago)

      expect { wf.succeed!; wf.save! }
        .to change { job.reload.state }.from("running").to("implemented")
    end

    it "does not transition Job on workflow.succeed! when Job has already moved past :running (auto-approval path)" do
      # Steps::PrOpen + AutoApprovalRule already advanced the Job
      # to :approved before the workflow succeeds. workflow.succeed
      # must not regress it back.
      job.update!(state: "approved", approved_at: Time.current, approved_via: "operator")
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)

      expect { wf.succeed!; wf.save! }
        .not_to change { job.reload.state }

      expect(job.reload.state).to eq("approved")
    end

    # Repro for Job 360's stuck state: workflow had a Run fail
    # mid-chain → cascaded → workflow → :failed → Job → :failed.
    # Operator clicked "Retry from failed step" → workflow.reopen
    # flipped :failed → :running but Job stayed :failed. The new
    # Run succeeded → workflow → :succeeded → propagate_succeed
    # found Job not :running and silently no-op'd. Job stayed
    # wedged at :failed forever.
    it "lifts a :failed Job through :queued → :implemented when workflow.succeed runs after a stuck reopen" do
      job.update!(state: "failed")
      wf = described_class.create!(job: job, trigger_kind: "pr_comment", state: "running", started_at: 1.minute.ago)

      expect { wf.succeed!; wf.save! }
        .to change { job.reload.state }.from("failed").to("implemented")
    end

    it "drives Job :failed → :running on workflow.reopen (Retry-from-failed-step)" do
      job.update!(state: "failed")
      wf = described_class.create!(job: job, trigger_kind: "pr_comment", state: "failed",
                                   started_at: 2.minutes.ago, finished_at: 1.minute.ago)

      expect { wf.reopen!; wf.save! }
        .to change { job.reload.state }.from("failed").to("running")
    end

    it "drives Job :queued → :running on workflow.reopen" do
      job.update!(state: "queued")
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "failed",
                                   started_at: 2.minutes.ago, finished_at: 1.minute.ago)

      expect { wf.reopen!; wf.save! }
        .to change { job.reload.state }.from("queued").to("running")
    end

    it "leaves Job state untouched on workflow.reopen when Job is already :running (no stuck propagation gap)" do
      job.update!(state: "running")
      wf = described_class.create!(job: job, trigger_kind: "pr_comment", state: "failed",
                                   started_at: 2.minutes.ago, finished_at: 1.minute.ago)

      expect { wf.reopen!; wf.save! }
        .not_to change { job.reload.state }
    end

    it "leaves Job state untouched on workflow.reopen for auto_merge workflows" do
      job.update!(state: "landing")
      wf = described_class.create!(job: job, trigger_kind: "auto_merge", state: "failed",
                                   started_at: 2.minutes.ago, finished_at: 1.minute.ago)

      expect { wf.reopen!; wf.save! }
        .not_to change { job.reload.state }
    end
  end

  describe "#fail cancels orphan active Runs but preserves Steps" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    it "moves queued/running Runs to :cancelled and leaves queued Steps alone (for retry-from-failed-step)" do
      done_step    = Step.create!(workflow: wf, kind: "prepare",   position: 0, state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      failed_step  = Step.create!(workflow: wf, kind: "implement", position: 1, state: "failed",    started_at: 1.minute.ago, finished_at: Time.current)
      queued_step  = Step.create!(workflow: wf, kind: "summarize", position: 2)  # queued — orphan tail
      tail_step    = Step.create!(workflow: wf, kind: "pr_open",   position: 3)  # queued — orphan tail

      done_run    = Run.create!(job: job, step: done_step,   trigger_kind: "initial", state: "succeeded")
      failed_run  = Run.create!(job: job, step: failed_step, trigger_kind: "initial", state: "failed")
      orphan_run  = Run.create!(job: job, step: queued_step, trigger_kind: "initial")  # queued — speculatively created

      wf.start!
      wf.fail!
      wf.save!

      expect(wf).to be_failed

      # Orphan active Run gets cancelled so Job#any_active_run? clears
      # and the Retry button reappears in the UI.
      expect(orphan_run.reload.state).to eq("cancelled")
      expect(orphan_run.finished_at).to be_present
      expect(orphan_run.run_resource_summary).to have_attributes(
        host_pressure_level: "unknown",
        host_sample_confidence: "unknown"
      )

      # Queued tail Steps stay queued so Retry-from-failed-step can
      # reopen the failed Step and the dispatcher can advance through
      # the chain.
      expect(queued_step.reload.state).to eq("queued")
      expect(tail_step.reload.state).to   eq("queued")

      # Already-terminal records are untouched.
      expect(done_step.reload.state).to   eq("succeeded")
      expect(done_run.reload.state).to    eq("succeeded")
      expect(failed_step.reload.state).to eq("failed")
      expect(failed_run.reload.state).to  eq("failed")
    end

    it "is idempotent — failing twice doesn't crash when there are no orphan Runs left" do
      Step.create!(workflow: wf, kind: "implement", position: 0, state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
      wf.start!
      wf.fail!
      wf.save!
      expect { wf.cancel_orphan_active_runs! }.not_to raise_error
    end

    it "does NOT cleanup the workspace (deliberate — retry-from-failed-step needs it)" do
      Step.create!(workflow: wf, kind: "implement", position: 0, state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
      wf.start!
      expect(WorkflowWorkspace).not_to receive(:cleanup_for)
      wf.fail!
      wf.save!
    end
  end

  describe "infrastructure workflow cleanup on fail" do
    let(:user) { Factories.user }
    let(:repo) { Factories.repository(user: user) }

    def make_infra_workflow
      infra_job = Job.create!(
        user: user,
        owner_user: user,
        repository: repo,
        kind: "main_grader",
        issue_title: "main_grader:abc123"
      )
      wf = described_class.create!(
        job: infra_job,
        trigger_kind: "main_grader",
        state: "running",
        started_at: 1.minute.ago
      )
      allow(wf).to receive(:dispatch_hook)
      wf
    end

    it "cleans up the workspace immediately on fail — no retry window holds it" do
      wf = make_infra_workflow
      allow(WorkflowWorkspace).to receive(:cleanup_for) do |w|
        w.update_columns(cleaned_up_at: Time.current)
      end

      wf.fail!
      wf.save!

      expect(WorkflowWorkspace).to have_received(:cleanup_for).with(wf)
      expect(wf.reload.cleaned_up_at).to be_present
    end

    it "leaves the retry_available? false after fail (workspace was cleaned)" do
      wf = make_infra_workflow
      allow(WorkflowWorkspace).to receive(:cleanup_for) do |w|
        w.update_columns(cleaned_up_at: Time.current)
      end

      wf.fail!
      wf.save!

      expect(wf.reload.retry_available?).to eq(false)
    end

    it "does NOT clean up on fail for a retryable (non-infrastructure) workflow" do
      retryable_wf = described_class.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)
      Step.create!(workflow: retryable_wf, kind: "implement", position: 0, state: "failed", started_at: 1.minute.ago, finished_at: Time.current)

      expect(WorkflowWorkspace).not_to receive(:cleanup_for)
      retryable_wf.fail!
      retryable_wf.save!

      expect(retryable_wf.reload.cleaned_up_at).to be_nil
      expect(retryable_wf.retry_available?).to eq(true)
    end
  end

  describe "#retry_available? and #reopen: latest-workflow guard" do
    it "retry_available? is true for the only (latest) failed workflow" do
      wf = described_class.create!(job: job, trigger_kind: "initial")
      wf.update_columns(state: "failed", finished_at: Time.current)
      expect(wf.retry_available?).to eq(true)
    end

    it "retry_available? is false for a non-latest failed workflow" do
      old_wf = described_class.create!(job: job, trigger_kind: "initial")
      new_wf = described_class.create!(job: job, trigger_kind: "retry")
      old_wf.update_columns(state: "failed", finished_at: 5.minutes.ago)
      new_wf.update_columns(state: "failed", finished_at: 1.minute.ago)

      expect(old_wf.retry_available?).to eq(false)
      expect(new_wf.retry_available?).to eq(true)
    end

    it "latest_for_job? returns true when this is the only workflow" do
      wf = described_class.create!(job: job, trigger_kind: "initial")
      expect(wf.latest_for_job?).to eq(true)
    end

    it "latest_for_job? returns false when a newer workflow exists" do
      old_wf = described_class.create!(job: job, trigger_kind: "initial")
      _new_wf = described_class.create!(job: job, trigger_kind: "retry")
      old_wf.update_columns(state: "failed", finished_at: 5.minutes.ago)
      expect(old_wf.latest_for_job?).to eq(false)
    end

    it "reopen is blocked for a non-latest workflow (guard prevents the transition)" do
      old_wf = described_class.create!(job: job, trigger_kind: "initial")
      new_wf = described_class.create!(job: job, trigger_kind: "retry")
      old_wf.update_columns(state: "failed", finished_at: 5.minutes.ago)
      new_wf.update_columns(state: "failed", finished_at: 1.minute.ago)

      old_wf.reopen!
      expect(old_wf.reload).to be_failed
    end

    it "reopen succeeds for the latest workflow" do
      wf = described_class.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)
      wf.fail!
      wf.save!

      wf.reopen!
      wf.save!
      expect(wf.reload).to be_running
    end
  end

  describe "artifacts" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    it "round-trips JSON-serialized values" do
      wf.set_artifact!("pr_title", "Add greeting helper")
      wf.set_artifact!("pr_body", "Adds a tiny greet helper.")
      reloaded = described_class.find(wf.id)
      expect(reloaded.artifact("pr_title")).to eq("Add greeting helper")
      expect(reloaded.artifact("pr_body")).to eq("Adds a tiny greet helper.")
    end

    it "is nil-safe for unset keys" do
      expect(wf.artifact("never_set")).to be_nil
    end

    it "preserves prior keys when setting a new one (merge, not replace)" do
      wf.set_artifact!("a", 1)
      wf.set_artifact!("b", 2)
      expect(wf.reload.artifacts).to eq("a" => 1, "b" => 2)
    end

    it "supports rich values (hashes, arrays — JSON serializes anything)" do
      wf.set_artifact!("test_plan", { steps: [ "rspec", "lint" ], note: "ok" })
      reloaded = described_class.find(wf.id)
      expect(reloaded.artifact("test_plan")).to eq("steps" => [ "rspec", "lint" ], "note" => "ok")
    end
  end

  describe "#current_iteration" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    it "returns nil when the workflow has no loop steps" do
      Step.create!(workflow: wf, kind: "implement", position: 0)

      expect(wf.current_iteration).to be_nil
    end

    it "returns the highest iteration across active loop instances" do
      Step.create!(workflow: wf, kind: "implement", position: 0, loop_id: "loop-a", iteration: 2, state: "queued")
      Step.create!(workflow: wf, kind: "summarize", position: 1, loop_id: "loop-b", iteration: 3, state: "running")
      Step.create!(workflow: wf, kind: "pr_open", position: 2, loop_id: "loop-a", iteration: 1, state: "queued")

      expect(wf.current_iteration).to eq(3)
    end

    it "ignores completed loop steps" do
      Step.create!(workflow: wf, kind: "implement", position: 0, loop_id: "loop-a", iteration: 4, state: "succeeded")
      Step.create!(workflow: wf, kind: "summarize", position: 1, loop_id: "loop-a", iteration: 2, state: "running")

      expect(wf.current_iteration).to eq(2)
    end

    it "returns nil when all loop steps are completed" do
      Step.create!(workflow: wf, kind: "implement", position: 0, loop_id: "loop-a", iteration: 1, state: "succeeded")
      Step.create!(workflow: wf, kind: "summarize", position: 1, loop_id: "loop-a", iteration: 2, state: "failed")

      expect(wf.current_iteration).to be_nil
    end
  end

  describe "#record_run_failure!" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial").tap(&:start!).tap(&:save!) }

    it "increments failure_count" do
      expect { wf.record_run_failure! }.to change { wf.reload.failure_count }.by(1)
    end

    it "auto-fails the Workflow when count crosses AppSetting.max_job_failures" do
      cap = AppSetting.max_job_failures
      cap.times { wf.record_run_failure! }
      expect(wf.reload).to be_failed
    end

    it "does not affect other workflows on the same Job (per-Workflow scope)" do
      other_wf = described_class.create!(job: job, trigger_kind: "pr_comment")
      cap = AppSetting.max_job_failures
      cap.times { wf.record_run_failure! }
      expect(other_wf.reload.state).to eq("queued")
      expect(other_wf.failure_count).to eq(0)
    end
  end

  describe "#succeed (Rebase → AutoMerge handoff)" do
    let(:user) { Factories.user(github_token: "ghp_test") }
    let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

    def landing_job
      job = Factories.job_record(user: user, repository: repository, issue_number: 1,
                                  pr_number: 1, state: "implemented")
      job.approve!(via: "github_review")
      job
    end

    it "calls LandingQueueProcessor.try_land! when a rebase workflow succeeds on an approved Job" do
      job = landing_job
      rebase_wf = Workflows::Rebase.instantiate(job: job)
      rebase_wf.update!(state: "running")

      allow(LandingQueueProcessor).to receive(:try_land!)

      rebase_wf.succeed!
      rebase_wf.save!

      expect(LandingQueueProcessor).to have_received(:try_land!).with(job)
    end

    it "skips LandingQueueProcessor.try_land! when the succeeding workflow is not a rebase" do
      job = landing_job
      initial_wf = described_class.create!(job: job, trigger_kind: "initial", state: "running")

      allow(LandingQueueProcessor).to receive(:try_land!)

      initial_wf.succeed!
      initial_wf.save!

      expect(LandingQueueProcessor).not_to have_received(:try_land!)
    end

    it "skips LandingQueueProcessor.try_land! when the Job is no longer approved" do
      job = Factories.job_record(user: user, repository: repository, issue_number: 1,
                                  pr_number: 1, state: "queued")
      rebase_wf = Workflows::Rebase.instantiate(job: job)
      rebase_wf.update!(state: "running")

      allow(LandingQueueProcessor).to receive(:try_land!)

      rebase_wf.succeed!
      rebase_wf.save!

      expect(LandingQueueProcessor).not_to have_received(:try_land!)
    end

    it "swallows hook exceptions so the workflow state transition still commits" do
      job = landing_job
      rebase_wf = Workflows::Rebase.instantiate(job: job)
      rebase_wf.update!(state: "running")

      allow(LandingQueueProcessor).to receive(:try_land!).and_raise(StandardError, "boom")

      expect {
        rebase_wf.succeed!
        rebase_wf.save!
      }.not_to raise_error

      expect(rebase_wf.reload).to be_succeeded
    end
  end

  describe "#succeed (AutoMerge → next landing handoff)" do
    let(:user) { Factories.user(github_token: "ghp_test") }
    let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

    it "kicks the landing queue once when an auto_merge workflow succeeds" do
      job = Factories.job_record(user: user, repository: repository, issue_number: 1,
                                  pr_number: 1, state: "landing")
      auto_merge_wf = Workflows::AutoMerge.instantiate(job: job)
      auto_merge_wf.update!(state: "running")

      allow(LandingQueueProcessor).to receive(:try_land!)

      auto_merge_wf.succeed!
      auto_merge_wf.save!

      expect(LandingQueueProcessor).to have_received(:try_land!).once.with(no_args)
    end
  end

  describe "#dispatch_hook (workflow-class hook dispatcher)" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    it "invokes the hook method on the matching Workflows::* template class" do
      allow(Workflows::Initial).to receive(:after_success)

      wf.send(:dispatch_hook, :after_success)

      expect(Workflows::Initial).to have_received(:after_success).with(wf)
    end

    it "logs and swallows exceptions raised by the hook" do
      allow(Workflows::Initial).to receive(:after_success).and_raise(StandardError, "boom")
      allow(Rails.logger).to receive(:warn)

      expect { wf.send(:dispatch_hook, :after_success) }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/after_success hook raised.*StandardError.*boom/)
    end

    it "no-ops for an unknown trigger_kind without raising" do
      wf.update_column(:trigger_kind, "no_longer_registered")

      expect { wf.send(:dispatch_hook, :after_success) }.not_to raise_error
    end
  end

  describe "Workflows::PrFeedback.after_success" do
    let(:job) { Factories.job }
    let!(:comment) do
      PrReviewComment.create!(
        job: job,
        pr_type: "direct",
        comment_kind: "issue",
        github_comment_id: 1,
        github_handle: "reviewer",
        attributed_to: "external",
        actionable: true,
        body: "Please fix this",
        handling_state: "active",
        comment_created_at: Time.iso8601("2026-05-17T18:00:00Z")
      )
    end
    let(:wf) do
      described_class.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "running",
        artifacts: { "pr_comments" => [
          { "id" => 1, "created_at" => "2026-05-17T18:00:00Z" },
          { "id" => 2, "created_at" => "2026-05-17T20:30:00Z" }
        ],
        "pr_review_comment_ids" => [ comment.id ] }
      )
    end

    it "marks the job's feedback as addressed and marks source comments handled" do
      Workflows::PrFeedback.after_success(wf)

      expect(job.reload.last_feedback_addressed_at).to be_within(1.second).of(Time.iso8601("2026-05-17T20:30:00Z"))
      expect(comment.reload.handling_state).to eq("handled")
      expect(comment.handled_at).to be_present
      expect(comment.actioned_at).to be_present
    end

    it "is a no-op when artifacts has no pr_comments" do
      wf.update!(artifacts: {})

      expect { Workflows::PrFeedback.after_success(wf) }.not_to change { job.reload.last_feedback_addressed_at }
    end

    it "marks source comments failed with the failed run outcome" do
      step = Step.create!(workflow: wf, kind: "respond", details: {}, state: "failed")
      Run.create!(job: job, step: step, trigger_kind: "pr_comment", state: "failed", agent_outcome: "rate_limit")

      Workflows::PrFeedback.after_fail(wf)

      comment.reload
      expect(comment.handling_state).to eq("failed")
      expect(comment.handling_failure_reason).to eq("rate_limit")
      expect(comment.actioned_at).to be_nil
    end
  end

  describe "coverage hit map blob helpers" do
    let(:wf) { described_class.create!(job: job, trigger_kind: "initial") }

    let(:hit_map) do
      {
        "app/models/user.rb" => { "1" => 3, "2" => 0, "5" => 1 },
        "app/models/post.rb" => { "10" => 1 }
      }
    end

    describe "#attach_coverage_hit_map!" do
      it "attaches a gzip-compressed JSON blob" do
        wf.attach_coverage_hit_map!(hit_map)
        expect(wf.coverage_hit_map).to be_attached
        expect(wf.coverage_hit_map.filename.to_s).to eq("coverage_hit_map.json.gz")
        expect(wf.coverage_hit_map.content_type).to eq("application/gzip")
      end
    end

    describe "#coverage_hit_map_data" do
      it "returns nil when no blob is attached" do
        expect(wf.coverage_hit_map_data).to be_nil
      end

      it "decompresses and parses the stored hit map" do
        wf.attach_coverage_hit_map!(hit_map)
        result = wf.coverage_hit_map_data
        expect(result).to eq(hit_map)
      end

      it "round-trips integer hit counts faithfully" do
        wf.attach_coverage_hit_map!(hit_map)
        result = wf.reload.coverage_hit_map_data
        expect(result.dig("app/models/user.rb", "1")).to eq(3)
        expect(result.dig("app/models/user.rb", "2")).to eq(0)
      end
    end

    describe "#purge_coverage_hit_map!" do
      it "removes the attachment" do
        wf.attach_coverage_hit_map!(hit_map)
        expect(wf.coverage_hit_map).to be_attached

        wf.purge_coverage_hit_map!
        expect(wf.reload.coverage_hit_map).not_to be_attached
      end
    end
  end

  describe "#schedule_auto_retry!" do
    let(:workflow) { job.latest_workflow }

    it "enqueues WorkEngine::ReconcileJob when the workflow is failed" do
      workflow.update_columns(state: "failed", finished_at: Time.current)

      expect {
        workflow.schedule_auto_retry!
      }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
        source: "Workflow",
        job_id: job.id,
        workflow_id: workflow.id,
        run_id: nil
      )
    end

    it "is a no-op when the workflow is not failed" do
      expect {
        workflow.schedule_auto_retry!
      }.not_to have_enqueued_job(WorkEngine::ReconcileJob)
    end
  end
end
