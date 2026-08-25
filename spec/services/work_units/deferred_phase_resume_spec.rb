require "rails_helper"

RSpec.describe WorkUnits::DeferredPhaseResume do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before do
    clear_enqueued_jobs
  end

  after do
    clear_enqueued_jobs
  end

  it "starts a WorkUnit-blocked workflow first step through the launcher" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", agent_provider: "codex")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, agent_provider: "codex")
    workflow.work_unit.block!(reason: "admission_control", details: { "action" => "delay_until" })

    expect(StepDispatcher).not_to receive(:resume_deferred_phase)

    result = described_class.call(workflow.id)

    expect(result).to be_started
    expect(result.run).to be_present
    expect(workflow.work_unit.reload).to be_queued
    expect(workflow.first_step.runs.reload).to include(result.run)
  end

  it "resumes a later queued step only after the WorkUnit scheduler passes" do
    job = Factories.job_record(user: user, repository: repository, state: "running", agent_provider: "codex")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, agent_provider: "codex")
    first_step = workflow.first_step
    first_run = first_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: "codex")
    first_step.update_columns(state: "succeeded", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    first_run.update_columns(state: "succeeded", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    next_step = workflow.steps.order(:position).detect { |step| step.id != first_step.id }
    workflow.work_unit.block!(reason: "provider_availability", details: { "provider" => "codex" })

    expect(WorkUnits::Scheduler).to receive(:evaluate!)
      .with(workflow.work_unit, step: next_step)
      .and_call_original

    result = described_class.call(workflow.id, next_step.id)

    expect(result).to be_started
    expect(result.run.step).to eq(next_step)
    expect(workflow.work_unit.reload).to be_queued
  end

  it "keeps a blocked WorkUnit blocked without falling through to legacy resume" do
    retry_at = 5.minutes.from_now
    job = Factories.job_record(user: user, repository: repository, state: "queued", agent_provider: "codex")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, agent_provider: "codex")
    workflow.work_unit.block!(reason: "provider_availability", details: { "provider" => "codex" })

    expect(StepDispatcher).not_to receive(:resume_deferred_phase)
    allow(WorkUnits::Scheduler).to receive(:evaluate!).and_return(
      WorkUnits::GateResult.block(reason: "provider_availability", retry_at: retry_at, details: { "provider" => "codex" })
    )

    expect {
      result = described_class.call(workflow.id)
      expect(result).to be_blocked
      expect(result.reason).to eq("provider_availability")
    }.to have_enqueued_job(WorkflowPhaseAdmissionJob).with(workflow.id)

    expect(workflow.work_unit.reload).to be_blocked
  end

  it "does not resume normal workflows without WorkUnits" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", agent_provider: "codex")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "queued", agent_provider: "codex")
    Step.create!(workflow: workflow, kind: "prepare", position: 1)

    expect(StepDispatcher).not_to receive(:resume_deferred_phase)

    result = described_class.call(workflow.id)

    expect(result.status).to eq("missing_work_unit")
    expect(result.run).to be_nil
  end

  it "preserves legacy resume behavior for replay workflows without WorkUnits" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", agent_provider: "codex")
    workflow = Workflow.create!(job: job, trigger_kind: "replay", state: "queued", agent_provider: "codex")
    Step.create!(workflow: workflow, kind: "prepare", position: 1)

    expect(StepDispatcher).to receive(:resume_deferred_phase).with(workflow.id, nil).and_return(:legacy_run)

    result = described_class.call(workflow.id)

    expect(result).to be_legacy
    expect(result.run).to eq(:legacy_run)
  end
end
