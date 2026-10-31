require "rails_helper"

RSpec.describe WorkUnits::Gates::PatientRebase do
  let(:job) do
    Factories.job_record(
      state: "running",
      pr_number: 42,
      branch_name: "syrus/issue-42"
    )
  end

  def attach_active_feedback
    workflow = Workflows::ChatFeedback.instantiate(job: job)
    unit = WorkUnit.create!(
      work_intent: WorkIntent.create!(
        kind: "chat_feedback", state: "requested", repository: job.repository,
        scope_type: "job", scope_id: job.id, actor: job.user, source_type: "spec"
      ),
      kind: "chat_feedback", state: "running", repository: job.repository,
      scope_type: "job", scope_id: job.id, workflow: workflow
    )
    unit.work_unit_members.create!(job: job, role: "primary")
    unit.work_unit_locks.create!(lock_key: "job:#{job.id}")
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
end
