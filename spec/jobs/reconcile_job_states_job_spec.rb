require "rails_helper"

RSpec.describe ReconcileJobStatesJob do
  include ActiveJob::TestHelper

  let(:job) do
    j = Factories.job
    j.runs.destroy_all
    j.workflows.destroy_all
    j
  end

  # Factories.job leaves an active WorkUnit behind, and every drift pair is
  # gated on "no active runtime work" -- without this the Job looks mid-flight
  # and no plan is ever produced.
  def finish_work_units!
    unit_ids = WorkUnitMember.where(job_id: job.id).select(:work_unit_id)
    WorkUnit.where(id: unit_ids).update_all(state: "succeeded", finished_at: Time.current)
  end

  def build_workflow(state:, trigger_kind: "pr_comment", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
    Workflow.create!(
      job: job, trigger_kind: trigger_kind, state: state,
      started_at: started_at,
      finished_at: %w[ succeeded failed cancelled ].include?(state) ? finished_at : nil
    )
  end

  # Every other queued/* pair was in the drift table; this one was not, and it
  # is the pair that costs an operator the most. A Workflow whose first Run
  # fails before the Workflow starts leaves the Job at :queued -- `mark_failed`
  # only transitions from :running -- so the Job reads healthy in every
  # surface, "Just failed" included, while nothing works on it. the queued-workflow lifecycle regression sat
  # like that for fifteen hours with three Jobs blocked behind it.
  # The repair must lift a Job to :running only when starting its latest
  # Workflow would have: otherwise the reconciler overrides a state the
  # lifecycle chose on purpose. Production repaired 75 lifecycle-owning
  # Workflows' Jobs from :queued and 41 implemented Jobs in ~2.5 days.
  # NY6 (decided A): cancelling a running Job's current Workflow leaves the Job
  # failed -- "needs an operator decision" -- and nothing relaunches a
  # deliberately stopped attempt, so lifting it to queued left a Job that read
  # "waiting to run" with no work behind it (Agreement.cancel_rules_disagree).
  describe "a failed Job whose latest Workflow was cancelled" do
    it "stays failed when the cancellation was deliberate" do
      workflow = build_workflow(state: "cancelled")
      workflow.set_artifact!("cancelled_reason", WorkUnits::WorkflowCancellation::OPERATOR_STALE_WORK_REASON)
      job.update!(state: "failed")
      finish_work_units!

      expect(ReconcileJobStatesJob::Plan.for(job.reload)).to be_nil
    end

    it "is still lifted to queued after a cancellation that will be relaunched" do
      workflow = build_workflow(state: "cancelled")
      workflow.set_artifact!("cancelled_reason", EpicWorkflowLock::BLOCK_REASON)
      job.update!(state: "failed")
      finish_work_units!

      expect(ReconcileJobStatesJob::Plan.for(job.reload)).to have_attributes(target_state: "queued")
    end
  end

  # Regression: a direct Job read :running for weeks while its only Workflow
  # sat blocked on an agent cannot-proceed report nobody answered. The blocked
  # Workflow's WorkUnit holds the Job on purpose, so nothing reconciled it.
  describe "a running Job whose latest Workflow has been blocked for days" do
    def blocked_workflow(blocked_at: 4.days.ago)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "blocked", started_at: blocked_at - 1.hour, finished_at: blocked_at)
      workflow.set_artifact!("cannot_proceed", { "reason" => "The macOS smoke test was routed to a Linux worker." })
      finish_work_units!
      WorkUnit.where(id: WorkUnitMember.where(job_id: job.id).select(:work_unit_id)).update_all(active_dedup_key: nil)
      attach_work_unit(workflow, state: "blocked", blocked_reason: "agent_cannot_proceed")
      job.update!(state: "running")
      workflow
    end

    it "moves the Job to failed with needs-attention and names the blocked reason" do
      workflow = blocked_workflow

      plan = ReconcileJobStatesJob::Plan.for(job.reload)
      expect(plan).to have_attributes(target_state: "failed")
      expect(plan.reason).to include("blocked", "routed to a Linux worker")

      plan.apply!

      expect(job.reload).to be_failed
      expect(job).to have_attributes(needs_attention: true, needs_attention_reason: "agent_cannot_proceed")
      expect(workflow.reload).to be_blocked
      expect(StateTransition.where(subject: job).last.metadata).to include("repair_reason" => plan.reason)
    end

    it "leaves the Job running while the block is recent" do
      blocked_workflow(blocked_at: 2.hours.ago)

      expect(ReconcileJobStatesJob::Plan.for(job.reload)).to be_nil
    end

    it "leaves the Job running while other work on it is runnable" do
      blocked_workflow
      other = Workflow.create!(job: job, trigger_kind: "pr_comment", state: "queued", created_at: 10.days.ago)
      attach_work_unit(other, state: "queued")

      expect(ReconcileJobStatesJob::Plan.for(job.reload)).to be_nil
    end

    it "is repaired by the work-engine reconciler" do
      blocked_workflow

      WorkEngine::Reconciler.call(source: "spec", job_id: job.id, execute_repairs: true)

      expect(job.reload).to be_failed
      expect(job.needs_attention_reason).to eq("agent_cannot_proceed")
    end

    it "comes back to running when the blocked Workflow is answered" do
      workflow = blocked_workflow
      ReconcileJobStatesJob::Plan.for(job.reload).apply!

      workflow.reload.resume_from_answer!
      workflow.save!

      expect(job.reload).to be_running
      expect(job.needs_attention?).to be(false)
    end
  end

  describe "lifting a Job to :running" do
    it "leaves a lifecycle-owning Workflow's Job where its start left it" do
      build_workflow(state: "running", trigger_kind: "main_branch_repair", finished_at: nil)
      job.update!(state: "queued")
      finish_work_units!

      expect(ReconcileJobStatesJob::Plan.for(job.reload)).to be_nil
    end

    it "keeps an implemented Job approvable under a non-approval-blocking follow-up" do
      build_workflow(state: "running", trigger_kind: "visual_diff", finished_at: nil)
      job.update!(state: "implemented")
      finish_work_units!

      expect(ReconcileJobStatesJob::Plan.for(job.reload)).to be_nil
    end

    it "keeps a Job implemented after its running Workflow already opened the PR" do
      workflow = build_workflow(state: "running", trigger_kind: "initial", finished_at: nil)
      workflow.steps.create!(kind: "pr_open", position: 3, state: "succeeded", finished_at: 1.minute.ago)
      workflow.steps.create!(kind: "grader", position: 4, state: "running", started_at: 30.seconds.ago)
      job.update!(state: "implemented")
      finish_work_units!

      expect(ReconcileJobStatesJob::Plan.for(job.reload)).to be_nil
    end

    it "still lifts an implemented Job under an approval-blocking follow-up" do
      build_workflow(state: "running", trigger_kind: "pr_comment", finished_at: nil)
      job.update!(state: "implemented")
      finish_work_units!

      plan = ReconcileJobStatesJob::Plan.for(job.reload)

      expect(plan&.target_state).to eq("running")
    end

    it "still lifts a queued Job under an ordinary running Workflow" do
      build_workflow(state: "running", trigger_kind: "initial", finished_at: nil)
      job.update!(state: "queued")
      finish_work_units!

      expect(ReconcileJobStatesJob::Plan.for(job.reload)&.target_state).to eq("running")
    end
  end

  describe "a workflow that failed while the Job never left :queued" do
    it "plans the Job to failed" do
      build_workflow(state: "failed", started_at: nil)
      job.update!(state: "queued")
      finish_work_units!

      plan = ReconcileJobStatesJob::Plan.for(job.reload)

      expect(plan).to be_present
      expect(plan.target_state).to eq("failed")
      expect(plan.reason).to match(/stuck at :queued/)
    end

    it "makes the Job discoverable in the Just failed folder" do
      build_workflow(state: "failed", started_at: nil)
      job.update!(state: "queued")
      finish_work_units!

      ReconcileJobStatesJob::Plan.for(job.reload).apply!

      expect(job.reload).to be_failed
    end

    # A Job with live work is mid-flight, not stranded -- the same guard every
    # other drift pair uses.
    it "leaves a Job alone while it still has active runtime work" do
      workflow = build_workflow(state: "failed", started_at: nil)
      job.update!(state: "queued")
      step = Step.create!(workflow: workflow, kind: "prepare", state: "running", position: 0)
      Run.create!(job: job, step: step, trigger_kind: "initial", state: "running")

      expect(ReconcileJobStatesJob::Plan.for(job.reload)).to be_nil
    end
  end

  it "does not derive Job state from lifecycle-owned child workflows" do
    build_workflow(state: "failed", trigger_kind: "visual_diff")
    job.update!(state: "implemented")
    finish_work_units!

    expect(ReconcileJobStatesJob::Plan.for(job.reload)).to be_nil
  end

  it "always delegates to the unified reconciler without mutating Jobs directly" do
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
end
