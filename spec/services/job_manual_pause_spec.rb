require "rails_helper"

RSpec.describe JobManualPause do
  def set_scheduler_gate(enabled)
    Feature.find_or_create_by!(slug: "work_units_scheduler") do |feature|
      feature.category = "Operations"
      feature.name = "Work units scheduler"
    end.update!(enabled: enabled)
  end

  def attach_work_unit(job, workflow, state: "queued")
    intent = WorkIntent.create!(
      kind: workflow.trigger_kind,
      state: "requested",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      actor: job.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: workflow.trigger_kind,
      state: state,
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      workflow: workflow
    )
    unit.work_unit_members.create!(job: job, role: "primary")
    unit
  end

  it "preserves manual pause on the Job when there are no active WorkUnits" do
    set_scheduler_gate(false)
    job = Factories.job_record

    described_class.pause!(job, by_user: job.user)

    expect(job.reload.manual_paused?).to be true
  end

  it "requests pause on active work units" do
    set_scheduler_gate(false)
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "queued")
    unit = attach_work_unit(job, workflow)

    described_class.pause!(job, by_user: job.user)

    expect(job.reload.manual_paused?).to be true
    expect(unit.reload.pause_requested?).to be true
  end

  it "clears active work unit pause requests when unpausing" do
    set_scheduler_gate(false)
    job = Factories.job_record(manual_paused: true, manual_paused_at: Time.current)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "queued")
    unit = attach_work_unit(job, workflow)
    unit.request_pause!
    allow(StepDispatcher).to receive(:resume_deferred_phase)

    described_class.unpause!(job)

    expect(job.reload.manual_paused?).to be false
    expect(unit.reload.pause_requested?).to be false
  end

  it "starts a WorkUnit-blocked workflow immediately after manual unpause" do
    set_scheduler_gate(true)
    job = Factories.job_record(manual_paused: true, manual_paused_at: Time.current)
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    unit = workflow.work_unit
    unit.request_pause!

    blocked_result = WorkUnits::Launcher.start!(workflow)
    expect(blocked_result).to be_blocked
    expect(workflow.first_step.runs).to be_empty

    expect {
      described_class.unpause!(job)
    }.to change { workflow.first_step.runs.reload.count }.by(1)

    expect(job.reload.manual_paused?).to be false
    expect(unit.reload).to have_attributes(
      state: "queued",
      blocked_reason: nil,
      pause_requested: false
    )
    expect(workflow.first_step.runs.last).to be_queued
  end
end
