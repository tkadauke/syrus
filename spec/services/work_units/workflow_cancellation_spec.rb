require "rails_helper"

RSpec.describe WorkUnits::WorkflowCancellation do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  it "cancels the workflow and records typed preemption on the owning work unit" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, idempotency_key: "cancel-spec")
    preempting_job = Factories.job_record(user: user, repository: repository)
    preempting = WorkUnits::Launcher.instantiate(kind: "initial", job: preempting_job, idempotency_key: "cancel-spec-keeper").work_unit

    described_class.cancel!(
      workflow,
      reason: Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON,
      by_work_unit: preempting,
      artifacts: { "cancelled_reason" => Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON }
    )

    expect(workflow.reload).to be_cancelled
    expect(workflow.artifact("cancelled_reason")).to eq(Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON)
    expect(workflow.work_unit.reload).to have_attributes(
      state: "cancelled",
      preemption_reason: Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON,
      preempted_by_work_unit_id: preempting.id
    )
  end

  it "syncs the work intent after cancellation records a superseding preemption reason" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, idempotency_key: "cancel-intent-sync-spec")

    described_class.cancel!(
      workflow,
      reason: "job_approved",
      artifacts: { "cancelled_reason" => "job_approved" }
    )

    expect(workflow.reload).to be_cancelled
    expect(workflow.work_unit.reload).to have_attributes(
      state: "cancelled",
      preemption_reason: "job_approved"
    )
    expect(workflow.work_unit.work_intent.reload).to be_cancelled
  end

  it "preserves legacy cancellation for workflows without work units" do
    workflow = Workflows::Initial.instantiate(job: job)

    expect {
      described_class.cancel!(
        workflow,
        reason: "job_closed",
        artifacts: { "start_cancelled_reason" => "job_closed" }
      )
    }.not_to raise_error

    expect(workflow.reload).to be_cancelled
    expect(workflow.artifact("start_cancelled_reason")).to eq("job_closed")
  end

  it "does not preempt the work unit when a stale workflow instance has already completed" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, idempotency_key: "stale-cancel-spec")
    stale_workflow = Workflow.find(workflow.id)

    workflow.update!(state: "succeeded", finished_at: Time.current)
    workflow.work_unit.mark_terminal!("succeeded")
    finished_at = workflow.work_unit.reload.finished_at

    described_class.cancel!(
      stale_workflow,
      reason: Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON,
      artifacts: { "cancelled_reason" => Workflow::SUPERSEDED_BY_NEWER_WORKFLOW_REASON }
    )

    expect(workflow.reload).to be_succeeded
    expect(workflow.artifact("cancelled_reason")).to be_nil
    expect(workflow.work_unit.reload).to have_attributes(
      state: "succeeded",
      preemption_reason: nil,
      preempted_by_work_unit_id: nil,
      finished_at: finished_at
    )
  end

  describe ".cancel_queued_retry_workflows_for_job!" do
    # RetryWorkflowEnqueuer tries RunCheckpointResume first and only falls
    # back to a plain "retry" Workflow when no safe checkpoint resume is
    # available, so a stale retry attempt can surface as either WorkUnit
    # kind -- both must be cancelled, or the missed one stays queued and
    # fires later against state the caller just settled.
    it "cancels a queued retry Workflow" do
      retry_workflow = Workflow.create!(job: job, trigger_kind: "retry", state: "queued")
      attach_work_unit(retry_workflow, member_jobs: [ job ], kind: "retry", state: "queued")

      described_class.cancel_queued_retry_workflows_for_job!(job: job, reason: "job_approved")

      expect(retry_workflow.reload).to be_cancelled
      expect(retry_workflow.artifact("retry_cancelled_reason")).to eq("job_approved")
    end

    it "cancels a queued checkpoint_resume Workflow" do
      checkpoint_resume_workflow = Workflow.create!(job: job, trigger_kind: "retry", state: "queued")
      attach_work_unit(checkpoint_resume_workflow, member_jobs: [ job ], kind: "checkpoint_resume", state: "queued")

      described_class.cancel_queued_retry_workflows_for_job!(job: job, reason: "job_approved")

      expect(checkpoint_resume_workflow.reload).to be_cancelled
      expect(checkpoint_resume_workflow.artifact("retry_cancelled_reason")).to eq("job_approved")
    end

    it "leaves queued Workflows of unrelated WorkUnit kinds alone" do
      auto_merge_workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "queued")
      attach_work_unit(auto_merge_workflow, member_jobs: [ job ], kind: "auto_merge", state: "queued")

      described_class.cancel_queued_retry_workflows_for_job!(job: job, reason: "job_approved")

      expect(auto_merge_workflow.reload).to be_queued
      expect(auto_merge_workflow.artifact("retry_cancelled_reason")).to be_nil
    end
  end
end
