require "rails_helper"

RSpec.describe WorkflowAdmissionCapacityWakeup do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def sleeper(reason:, state: "queued")
    job = Factories.job_record(user: user, repository: repository, state: state == "running" ? "running" : "queued")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, agent_provider: "codex")
    workflow.update!(state: state)
    workflow.work_unit.block!(
      reason: WorkUnits::StartBlock.work_unit_reason_for(reason),
      details: { "start_blocked_reason" => reason }
    )
    workflow
  end

  it "recognizes normal admission sleepers, landing admission sleepers, and resource safety sleepers" do
    normal = sleeper(reason: StepDispatcher::ADMISSION_BLOCK_REASON)
    landing = sleeper(reason: "landing start blocked: workflow admission budget")
    resource = sleeper(reason: StepDispatcher::PAUSE_REASON_RESOURCE_SAFETY)
    manual = sleeper(reason: StepDispatcher::MANUAL_PAUSE_REASON)

    expect(described_class.admission_or_resource_paused?(normal)).to be(true)
    expect(described_class.admission_or_resource_paused?(landing)).to be(true)
    expect(described_class.admission_or_resource_paused?(resource)).to be(true)
    expect(described_class.admission_or_resource_paused?(manual)).to be(false)
  end

  it "wakes a bounded set of deferred admission workflows and reprocesses landing" do
    first = sleeper(reason: StepDispatcher::ADMISSION_BLOCK_REASON)
    second = sleeper(reason: "landing start blocked: workflow admission budget")
    sleeper(reason: StepDispatcher::ADMISSION_BLOCK_REASON)

    expect {
      result = described_class.call(limit: 2)
      expect(result.workflow_ids).to eq([ first.id, second.id ])
    }.to have_enqueued_job(WorkflowPhaseAdmissionJob).with(first.id)
      .and have_enqueued_job(WorkflowPhaseAdmissionJob).with(second.id)
      .and have_enqueued_job(LandingQueueProcessorJob)
  end

  it "ignores artifact-only admission sleepers without WorkUnit block state" do
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    workflow = Workflow.create!(
      job: job,
      user: user,
      trigger_kind: "replay",
      agent_provider: "codex",
      state: "queued",
      artifacts: { "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON }
    )

    expect {
      result = described_class.call
      expect(result.workflow_ids).to eq([])
    }.not_to have_enqueued_job(WorkflowPhaseAdmissionJob).with(workflow.id)
  end

  it "wakes WorkUnit-blocked admission workflows without workflow artifacts" do
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, agent_provider: "codex")
    workflow.work_unit.block!(
      reason: "admission_control",
      blocked_until: 5.minutes.from_now,
      details: { "action" => "delay_until" }
    )

    expect {
      result = described_class.call
      expect(result.workflow_ids).to eq([ workflow.id ])
    }.to have_enqueued_job(WorkflowPhaseAdmissionJob).with(workflow.id)
      .and have_enqueued_job(LandingQueueProcessorJob)
  end

  it "does not enqueue anything when no workflows are deferred" do
    expect {
      result = described_class.call
      expect(result.workflow_ids).to eq([])
    }.not_to have_enqueued_job(WorkflowPhaseAdmissionJob)
  end
end
