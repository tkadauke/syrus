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

  it "marks an active Workflow terminal when its WorkUnit is already terminal" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.update_columns(state: "running", started_at: 5.minutes.ago)
    workflow.work_unit.mark_terminal!("failed")

    described_class.call(workflow)

    expect(workflow.reload).to be_failed
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
end
