require "rails_helper"

RSpec.describe WorkflowStepWorkerSlot do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }
  let(:workflow) { Workflows::Initial.instantiate(job: job, agent_provider: "codex") }
  let(:run) { create_run_for(workflow) }

  before do
    AppSetting.current.update!(workflow_step_worker_slot_admission_enabled: true)
    allow(SyrusVersion).to receive(:hostname).and_return("worker-a")
    allow(WorkerStorageIdentity).to receive(:queue_key).and_return("storage-a")
    allow(InstanceVersion).to receive(:worker_queue_live?).and_return(true)
  end

  it "acquires one active slot for the worker storage key" do
    decision = described_class.acquire_for(run)

    expect(decision).to be_acquired
    expect(described_class.active.pluck(:worker_key)).to eq([ "storage:storage-a" ])
  end

  it "defers a second active step on the same worker key" do
    described_class.acquire_for(run)
    second = another_run(issue_number: 601)

    decision = described_class.acquire_for(second)

    expect(decision).to be_deferred
    expect(decision.reason).to eq("worker_slot_busy")
    expect(decision.delay).to eq(described_class::RETRY_DELAY)
    expect(second.reload).to be_queued
  end

  it "releases the slot when the run reaches a terminal state" do
    described_class.acquire_for(run)
    run.start!
    run.save!

    expect {
      run.succeed!
      run.save!
    }.to change { described_class.active.count }.from(1).to(0)

    expect(described_class.last).to have_attributes(released_at: be_present, active_slot_key: nil)
  end

  it "cleans up a dead worker slot before acquiring" do
    described_class.acquire_for(run)
    allow(InstanceVersion).to receive(:worker_queue_live?).with("resume-storage-a").and_return(false)
    replacement = another_run(issue_number: 602)

    decision = described_class.acquire_for(replacement)

    expect(decision).to be_acquired
    expect(described_class.active.pluck(:run_id)).to eq([ replacement.id ])
    expect(described_class.where(run_id: run.id).last.release_reason).to eq("worker_dead")
  end

  it "does nothing while the feature gate is disabled" do
    AppSetting.current.update!(workflow_step_worker_slot_admission_enabled: false)

    expect(described_class.acquire_for(run)).to be_acquired
    expect(described_class.count).to eq(0)
  end

  def another_run(issue_number:)
    other_job = Factories.job_record(user: user, repository: repository, state: "queued", issue_number: issue_number)
    other_workflow = Workflows::Initial.instantiate(job: other_job, agent_provider: "codex")
    create_run_for(other_workflow)
  end

  def create_run_for(target_workflow)
    target_workflow.first_step.runs.create!(
      job: target_workflow.job,
      trigger_kind: target_workflow.trigger_kind,
      agent_provider: target_workflow.agent_provider
    )
  end
end
