require "rails_helper"

RSpec.describe WorkUnits::Gates::PatientRebase do
  let(:job) do
    Factories.job_record(
      state: "running",
      pr_number: 42,
      branch_name: "syrus/issue-42"
    )
  end

  def attach_active_feedback(target = job)
    workflow = Workflows::ChatFeedback.instantiate(job: target)
    unit = WorkUnit.create!(
      work_intent: WorkIntent.create!(
        kind: "chat_feedback", state: "requested", repository: target.repository,
        scope_type: "job", scope_id: target.id, actor: target.user, source_type: "spec"
      ),
      kind: "chat_feedback", state: "running", repository: target.repository,
      scope_type: "job", scope_id: target.id, workflow: workflow
    )
    unit.work_unit_members.create!(job: target, role: "primary")
    unit.work_unit_locks.create!(lock_key: "job:#{target.id}")
    workflow.update_columns(state: "running", started_at: 1.minute.ago)
    [ workflow, unit ]
  end

  it "defers a system rebase until active feedback has finished, then starts it" do
    feedback, feedback_unit = attach_active_feedback
    rebase = RebaseWorkflowSelector.instantiate(
      job: job,
      artifacts: { "repair_reason" => "base recovered" }
    )

    expect {
      result = WorkUnits::Launcher.start!(rebase)
      expect(result).to be_blocked
      expect(result.reason).to eq(described_class::REASON)
    }.not_to have_enqueued_job(RunJob)

    expect(rebase.reload.artifact("requested_by")).to eq("system")
    expect(rebase.work_unit).to have_attributes(
      state: "blocked",
      blocked_reason: described_class::REASON
    )
    expect(feedback.reload).to be_running

    push = feedback.steps.find_by!(kind: "push")
    push.update_columns(state: "succeeded", finished_at: Time.current)
    feedback.update_columns(state: "succeeded", finished_at: Time.current)
    feedback_unit.mark_terminal!("succeeded")

    expect(push.reload).to be_succeeded

    expect {
      result = WorkUnits::Launcher.start!(rebase.reload)
      expect(result).to be_started
    }.to have_enqueued_job(RunJob)
  end

  # Regression: a feedback workflow the agent blocked kept its unit active
  # indefinitely, and the system rebase behind it never started.
  it "does not wait on a feedback workflow that is blocked for operator attention" do
    feedback, feedback_unit = attach_active_feedback
    feedback.update_columns(state: "blocked", finished_at: Time.current)
    feedback_unit.update_columns(state: "blocked", blocked_reason: "agent_cannot_proceed")
    rebase = RebaseWorkflowSelector.instantiate(job: job, artifacts: { "repair_reason" => "base recovered" })

    expect {
      result = WorkUnits::Launcher.start!(rebase)
      expect(result).to be_started
    }.to have_enqueued_job(RunJob)
  end

  # Regression, found by the simulator fuzzer: CI failed on a stack member
  # while an epic-wide rebase was queued. The member's repair was held back
  # by the epic-wide rebase, and the rebase waited patiently for the repair,
  # so each waited on the other forever.
  it "does not wait on a member workflow that is held back behind this rebase" do
    feedback, feedback_unit = attach_active_feedback
    feedback.update_columns(state: "queued", started_at: nil)
    feedback_unit.update_columns(state: "queued")
    rebase = RebaseWorkflowSelector.instantiate(job: job, artifacts: { "repair_reason" => "base recovered" })
    StepDispatcher.record_start_blocked!(
      feedback.reload,
      StepDispatcher::EPIC_WIDE_BLOCK_REASON,
      backoff: StepDispatcher::START_BLOCKED_BACKOFF,
      details: { "blocking_workflow_id" => rebase.id, "blocking_trigger_kind" => rebase.trigger_kind }
    )

    expect(described_class.call(rebase.work_unit)).to be_pass
  end

  it "still waits on a member workflow held back behind a different workflow" do
    feedback, feedback_unit = attach_active_feedback
    feedback.update_columns(state: "queued", started_at: nil)
    feedback_unit.update_columns(state: "queued")
    rebase = RebaseWorkflowSelector.instantiate(job: job, artifacts: { "repair_reason" => "base recovered" })
    StepDispatcher.record_start_blocked!(
      feedback.reload,
      StepDispatcher::EPIC_WIDE_BLOCK_REASON,
      backoff: StepDispatcher::START_BLOCKED_BACKOFF,
      details: { "blocking_workflow_id" => rebase.id + 1000 }
    )

    result = described_class.call(rebase.work_unit)
    expect(result).not_to be_pass
    expect(result.reason).to eq(described_class::REASON)
  end

  it "lets an explicitly requested rebase start without waiting" do
    feedback, = attach_active_feedback
    rebase = RebaseWorkflowSelector.instantiate(job: job, requested_by: "user")

    expect {
      result = WorkUnits::Launcher.start!(rebase)
      expect(result).to be_started
    }.to have_enqueued_job(RunJob)

    expect(rebase.reload.artifact("requested_by")).to eq("user")
    expect(feedback.reload).to be_running
  end

  it "does not wait for a workflow parked on an operator answer" do
    feedback, = attach_active_feedback
    feedback.steps.where(state: "queued").first!.update_columns(state: "awaiting_answer")
    rebase = RebaseWorkflowSelector.instantiate(job: job)

    expect {
      result = WorkUnits::Launcher.start!(rebase)
      expect(result).to be_started
    }.to have_enqueued_job(RunJob)

    expect(feedback.reload).to be_running
  end

  it "defers a system stack rebase for active feedback on a non-root member" do
    child = Factories.job_record(
      user: job.user,
      repository: job.repository,
      state: "running",
      issue_number: 43,
      pr_number: 43,
      branch_name: "syrus/issue-43"
    )
    child.update_columns(parent_job_id: job.id)
    feedback, = attach_active_feedback(child)
    rebase = RebaseWorkflowSelector.instantiate(job: job)

    expect(rebase.trigger_kind).to eq("stack_rebase")
    expect(rebase.work_unit.work_unit_members.map(&:job_id)).to include(job.id, child.id)

    expect {
      result = WorkUnits::Launcher.start!(rebase)
      expect(result).to be_blocked
      expect(result.reason).to eq(described_class::REASON)
    }.not_to have_enqueued_job(RunJob)

    expect(rebase.work_unit.reload.blocked_details).to include("blocking_workflow_id" => feedback.id)
    expect(feedback.reload).to be_running
  end
end
