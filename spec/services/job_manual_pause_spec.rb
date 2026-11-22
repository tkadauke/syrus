require "rails_helper"

RSpec.describe JobManualPause do
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
    job = Factories.job_record

    described_class.pause!(job, by_user: job.user)

    expect(job.reload.manual_paused?).to be true
  end

  it "requests pause on active work units" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "queued")
    unit = attach_work_unit(job, workflow)

    described_class.pause!(job, by_user: job.user)

    expect(job.reload.manual_paused?).to be true
    expect(unit.reload.pause_requested?).to be true
  end

  it "clears active work unit pause requests when unpausing" do
    job = Factories.job_record(manual_paused: true, manual_paused_at: Time.current)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "queued")
    unit = attach_work_unit(job, workflow)
    unit.request_pause!
    allow(StepDispatcher).to receive(:resume_deferred_phase)

    described_class.unpause!(job)

    expect(job.reload.manual_paused?).to be false
    expect(unit.reload.pause_requested?).to be false
  end

  # NY27 (decided A): a started landing paused by hand gives the repository's
  # landing slot back. Unpausing must take it again, or wait its turn when
  # another landing took it meanwhile.
  describe "a started landing paused by hand" do
    def paused_started_landing
      repository = Factories.repository
      job = Factories.job_record(user: repository.user, repository: repository, state: "landing",
                                 manual_paused: true, manual_paused_at: Time.current)
      workflow = WorkUnits::Launcher.instantiate(kind: "auto_merge", job: job)
      workflow.update!(state: "running", started_at: 1.minute.ago)
      Run.create!(job: job, step: workflow.first_step, trigger_kind: workflow.trigger_kind, state: "queued")
      unit = workflow.work_unit
      unit.mark_running!
      landing_key = unit.work_unit_locks.active.find_by!("lock_key LIKE ?", "landing:%").lock_key
      unit.request_pause!
      unit.block!(reason: "manual_pause")
      [ job, unit, landing_key ]
    end

    before { allow(WorkUnits::DeferredPhaseResume).to receive(:call) }

    it "takes the landing slot back on unpause when it is free" do
      job, unit, landing_key = paused_started_landing
      expect(unit.work_unit_locks.active.where(lock_key: landing_key)).not_to exist

      described_class.unpause!(job)

      expect(unit.reload).to be_running
      expect(unit.work_unit_locks.active.where(lock_key: landing_key)).to exist
    end

    it "waits its turn on unpause instead of failing when another landing took the slot" do
      job, unit, landing_key = paused_started_landing
      other_job = Factories.job_record(user: job.user, repository: job.repository, state: "landing")
      other = WorkUnits::Launcher.instantiate(kind: "auto_merge", job: other_job).work_unit
      expect(other.work_unit_locks.active.where(lock_key: landing_key)).to exist

      expect { described_class.unpause!(job) }.not_to raise_error

      expect(job.reload.manual_paused?).to be false
      expect(unit.reload).to be_queued
      expect(unit.work_unit_locks.active.where(lock_key: landing_key)).not_to exist
      expect(other.work_unit_locks.active.where(lock_key: landing_key)).to exist
    end
  end

  it "restores a running unit after a mid-workflow manual pause" do
    job = Factories.job_record(manual_paused: true, manual_paused_at: Time.current)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 2.minutes.ago)
    unit = attach_work_unit(job, workflow, state: "running")
    unit.request_pause!
    unit.block!(reason: "manual_pause")
    allow(WorkUnits::DeferredPhaseResume).to receive(:call)

    described_class.unpause!(job)

    expect(unit.reload).to have_attributes(state: "running", blocked_reason: nil, pause_requested: false)
  end

  it "starts a WorkUnit-blocked workflow immediately after manual unpause" do
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
