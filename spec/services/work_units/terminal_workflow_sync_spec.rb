require "rails_helper"

RSpec.describe WorkUnits::TerminalWorkflowSync do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  it "marks an active WorkUnit terminal when its workflow is already terminal" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.update_columns(state: "cancelled", finished_at: 1.minute.ago)
    workflow.work_unit.work_unit_locks.create!(lock_key: "spec:terminal-sync:#{workflow.id}")

    described_class.call(workflow)

    expect(workflow.work_unit.reload).to have_attributes(state: "cancelled")
    expect(workflow.work_unit.work_unit_locks.active).to be_empty
  end

  # Regression: Workflow#terminal? and Workflow.terminal both count `blocked`,
  # but WorkUnit has no blocked outcome, so mark_terminal!("blocked") raised
  # ArgumentError. This runs inside the reconciler's classification pass, so a
  # single blocked Workflow with an active WorkUnit crashed every reconciler
  # run -- stale runs went unreaped and nothing self-healed until it cleared.
  it "leaves a blocked workflow's WorkUnit alone instead of raising" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.update_columns(state: "blocked")

    expect { described_class.call(workflow) }.not_to raise_error
    expect(workflow.work_unit.reload).to be_active
  end

  it "survives a blocked workflow when sweeping a whole job" do
    blocked = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    blocked.update_columns(state: "blocked")

    expect { described_class.for_job(job.reload) }.not_to raise_error
  end

  it "marks an active Workflow terminal when its WorkUnit is already terminal" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.update_columns(state: "running", started_at: 5.minutes.ago)
    workflow.work_unit.mark_terminal!("failed")

    expect(workflow).to receive(:schedule_auto_retry!).and_call_original
    expect(workflow).to receive(:enforce_job_workflow_runaway_limits_on_fail!).and_call_original

    described_class.call(workflow)

    expect(workflow.reload).to be_failed
    expect(workflow.finished_at).to be_present
  end

  it "runs completion callbacks when a WorkUnit succeeds a queued Workflow" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.update_columns(state: "queued", started_at: nil)
    workflow.work_unit.mark_terminal!("succeeded")

    expect(workflow).to receive(:wake_workflow_admission_after_completion!).and_call_original
    expect(workflow).to receive(:record_workflow_activity_state_change!).and_call_original

    described_class.call(workflow)

    expect(workflow.reload).to be_succeeded
    expect(workflow).to have_attributes(started_at: be_present, finished_at: be_present)
  end

  it "cancels an active Workflow when its WorkUnit is already cancelled" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.update_columns(state: "queued")
    workflow.work_unit.mark_terminal!("cancelled")

    described_class.call(workflow)

    expect(workflow.reload).to be_cancelled
    expect(workflow.artifact("cancelled_reason")).to eq("terminal_work_unit")
  end

  it "does not terminalize a Workflow owned by an active replacement WorkUnit" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.update_columns(state: "running", started_at: 5.minutes.ago)
    stale_unit = workflow.work_unit
    stale_unit.mark_terminal!("cancelled")
    replacement_intent = WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      actor: job.user,
      source_type: "spec"
    )
    replacement = WorkUnit.new(
      work_intent: replacement_intent,
      kind: "initial",
      state: "running",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      workflow: workflow
    )
    replacement.save!(validate: false)

    described_class.call(workflow)

    expect(workflow.reload).to be_running
  end

  it "does not change non-terminal workflow ownership" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)

    expect {
      described_class.call(workflow)
    }.not_to change { workflow.work_unit.reload.state }
  end

  it "normalizes all terminal workflows for a job" do
    first = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    first.update_columns(state: "succeeded", finished_at: 2.minutes.ago)
    first.work_unit.work_unit_locks.create!(lock_key: "spec:terminal-sync:first:#{first.id}")
    first.work_unit.mark_running!
    first.work_unit.work_unit_locks.active.find_each(&:release!)
    second = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)
    second.update_columns(state: "cancelled", finished_at: 1.minute.ago)
    second.work_unit.mark_running!

    described_class.for_job(job)

    expect(first.work_unit.reload).to have_attributes(state: "succeeded")
    expect(second.work_unit.reload).to have_attributes(state: "cancelled")
    expect(first.work_unit.work_unit_locks.active).to be_empty
    expect(second.work_unit.work_unit_locks.active).to be_empty
  end

  it "normalizes active workflows with terminal WorkUnits for a non-closed job" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.update_columns(state: "queued")
    workflow.work_unit.mark_terminal!("cancelled")
    job.update_columns(state: "running")

    described_class.for_job(job)

    expect(workflow.reload).to be_cancelled
    expect(workflow.artifact("cancelled_reason")).to eq("terminal_work_unit")
  end

  it "leaves active workflows with terminal WorkUnits reportable for closed jobs" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.update_columns(state: "queued")
    workflow.work_unit.mark_terminal!("cancelled")
    job.update_columns(state: "closed", finished_at: 1.minute.ago, closure_reason: "operator_cancelled")

    described_class.for_job(job)

    expect(workflow.reload).to be_queued
  end
end
