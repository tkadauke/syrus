require "rails_helper"

RSpec.describe "Workflow work unit lifecycle" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  it "mirrors workflow start on its work unit" do
    workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)

    expect {
      workflow.start!
    }.to change { workflow.work_unit.reload.state }.from("queued").to("running")

    expect(workflow.work_unit.started_at).to be_present
    expect(workflow.work_unit.finished_at).to be_nil
  end

  it "mirrors workflow terminal state on its work unit" do
    workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)
    workflow.start!

    expect {
      workflow.succeed!
    }.to change { workflow.work_unit.reload.state }.from("running").to("succeeded")

    expect(workflow.work_unit.finished_at).to be_present
  end

  it "keeps retry-from-failed-step on the same work unit" do
    workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)
    unit = workflow.work_unit
    initial_lock_id = unit.work_unit_locks.active.pick(:id)

    workflow.fail!
    expect(unit.reload.work_unit_locks.active).to be_empty

    workflow.reopen!

    expect(workflow.work_unit).to eq(unit)
    expect(unit.reload).to have_attributes(state: "running", finished_at: nil)
    expect(unit.work_unit_locks.active.pluck(:lock_key)).to eq([ "job:#{job.id}" ])
    expect(unit.work_unit_locks.active.pick(:id)).not_to eq(initial_lock_id)
  end

  it "does not reopen a failed workflow when another active unit owns its lock" do
    workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)
    unit = workflow.work_unit
    workflow.fail!

    other_job = Factories.job_record(user: user, repository: repository, issue_number: 998)
    other_workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: other_job)
    other_workflow.work_unit.work_unit_locks.create!(lock_key: "job:#{job.id}")

    expect {
      workflow.reopen!
    }.to raise_error(WorkUnits::Launcher::LockConflict, /job:#{job.id}/)

    expect(workflow.reload).to be_failed
    expect(unit.reload).to be_failed
    expect(unit.work_unit_locks.active).to be_empty
  end
end
