require "rails_helper"

RSpec.describe UrgentJobClosedJob do
  include ActiveJob::TestHelper

  let(:repository) { Factories.repository }
  let(:user) { repository.user }

  def create_urgent_job!(state: "closed")
    Factories.job_record(
      user: user,
      repository: repository,
      priority: "urgent",
      state: state
    )
  end

  def create_blocked_workflow!
    job = Factories.job_record(user: user, repository: repository, priority: "medium", state: "queued")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.work_unit.block!(
      reason: "urgent_job_active",
      blocked_until: 5.minutes.from_now,
      details: { "start_blocked_reason" => StepDispatcher::URGENT_BLOCK_REASON }
    )
    step = workflow.first_step
    [workflow, step]
  end

  it "starts held workflows when no open urgent jobs remain" do
    create_urgent_job!(state: "closed")
    workflow, step = create_blocked_workflow!

    expect(WorkUnits::Launcher).to receive(:start!).with(workflow).once.and_call_original
    expect {
      described_class.new.perform(repository.id)
    }.to change { step.runs.count }.by(1)
  end

  it "starts WorkUnit-blocked workflows even when legacy artifacts are absent" do
    create_urgent_job!(state: "closed")
    job = Factories.job_record(user: user, repository: repository, priority: "medium", state: "queued")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.work_unit.block!(
      reason: "urgent_job_active",
      blocked_until: 5.minutes.from_now,
      details: { "preempted_by_job_id" => 123 }
    )

    expect(WorkUnits::Launcher).to receive(:start!).with(workflow).once.and_call_original
    expect {
      described_class.new.perform(repository.id)
    }.to change { workflow.first_step.runs.count }.by(1)
  end

  it "does not start workflows when another urgent job is still open" do
    create_urgent_job!(state: "closed")
    create_urgent_job!(state: "queued")
    _workflow, step = create_blocked_workflow!

    expect {
      described_class.new.perform(repository.id)
    }.not_to change { Run.count }
  end

  it "does not start workflows blocked for a different reason" do
    create_urgent_job!(state: "closed")
    workflow, step = create_blocked_workflow!
    workflow.work_unit.block!(reason: "manual_pause")

    expect {
      described_class.new.perform(repository.id)
    }.not_to change { Run.count }
  end

  it "does not start workflows from a different repository" do
    create_urgent_job!(state: "closed")
    other_repo = Factories.repository
    other_job = Factories.job_record(user: other_repo.user, repository: other_repo, priority: "medium", state: "queued")
    other_workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: other_job)
    other_step = other_workflow.first_step
    other_workflow.work_unit.block!(reason: "urgent_job_active")

    expect {
      described_class.new.perform(repository.id)
    }.not_to change { other_step.runs.count }
  end

  it "still starts replay workflows recorded only in legacy artifacts" do
    create_urgent_job!(state: "closed")
    job = Factories.job_record(user: user, repository: repository, priority: "medium", state: "queued")
    workflow = Workflow.create!(job: job, trigger_kind: "replay", state: "queued")
    step = Step.create!(workflow: workflow, kind: "implement", position: 0)
    workflow.update!(artifacts: { "start_blocked_reason" => StepDispatcher::URGENT_BLOCK_REASON })

    expect(WorkUnits::Launcher).to receive(:start!).with(workflow).once.and_call_original
    expect {
      described_class.new.perform(repository.id)
    }.to change { step.runs.count }.by(1)
  end

  it "ignores migrated artifact-only workflows without WorkUnit block state" do
    create_urgent_job!(state: "closed")
    job = Factories.job_record(user: user, repository: repository, priority: "medium", state: "queued")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "queued")
    step = Step.create!(workflow: workflow, kind: "implement", position: 0)
    workflow.update!(artifacts: { "start_blocked_reason" => StepDispatcher::URGENT_BLOCK_REASON })

    expect {
      described_class.new.perform(repository.id)
    }.not_to change { step.runs.count }
  end

  it "is a no-op for an unknown repository id" do
    expect {
      described_class.new.perform(0)
    }.not_to raise_error
  end
end
