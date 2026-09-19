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

  it "reactivates a terminal WorkUnit when its Workflow is still running" do
    job = Factories.job_record(user: user, repository: repository, state: "running", agent_provider: "codex")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, agent_provider: "codex")
    first_step = workflow.first_step
    first_run = first_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: "codex")
    ordered_steps = workflow.steps.order(:position).to_a
    next_step = ordered_steps.detect { |step| step.id != first_step.id }
    tail_step = ordered_steps.detect { |step| step.position > next_step.position }
    workflow.update_columns(state: "running", started_at: 10.minutes.ago)
    first_step.update_columns(state: "succeeded", started_at: 10.minutes.ago, finished_at: 9.minutes.ago)
    first_run.update_columns(state: "succeeded", started_at: 10.minutes.ago, finished_at: 9.minutes.ago)
    next_step.update_columns(state: "queued", started_at: nil, finished_at: nil)
    tail_step.update_columns(state: "cancelled", started_at: nil, finished_at: 8.minutes.ago) if tail_step
    workflow.work_unit.mark_terminal!("failed")
    workflow.work_unit.work_intent.fail!

    result = described_class.call(workflow.id, next_step.id)

    expect(result).to be_started
    expect(result.run.step).to eq(next_step)
    expect(workflow.work_unit.reload).to be_running
    expect(workflow.work_unit.work_intent.reload).to be_requested
    expect(tail_step.reload).to be_queued if tail_step
  end

  it "does not resume a step whose DAG dependencies are not ready" do
    feature = Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |record|
      record.name = "Distributed workflow DAG"
      record.category = "Specs"
    end
    feature.update!(
      name: "Distributed workflow DAG",
      category: "Specs",
      enabled: true
    )
    Feature.clear_enabled_cache!
    repository.update!(distributed_workflow_dag_enabled: true)
    job = Factories.job_record(user: user, repository: repository, state: "running", agent_provider: "codex")
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      state: "running",
      agent_provider: "codex",
      chain_template: []
    )
    attach_work_unit(workflow, state: "running")
    stale_barrier = Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 1,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop",
      placement_policy: Step::PlacementPolicy::CONTROL_PLANE
    )
    tail = Step.create!(
      workflow: workflow,
      kind: "summarize",
      position: 2,
      state: "queued",
      depends_on_ids: [ stale_barrier.id ]
    )

    result = described_class.call(workflow.id, tail.id)

    expect(result.status).to eq("not_ready")
    expect(result.run).to be_nil
    expect(tail.runs).to be_empty
  end

  it "resumes a tail step after a later retry-until barrier succeeds" do
    feature = Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |record|
      record.name = "Distributed workflow DAG"
      record.category = "Specs"
    end
    feature.update!(
      name: "Distributed workflow DAG",
      category: "Specs",
      enabled: true
    )
    Feature.clear_enabled_cache!
    repository.update!(distributed_workflow_dag_enabled: true)
    job = Factories.job_record(user: user, repository: repository, state: "running", agent_provider: "codex")
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      state: "running",
      agent_provider: "codex",
      chain_template: []
    )
    attach_work_unit(workflow, state: "running")
    stale_barrier = Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 1,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop",
      placement_policy: Step::PlacementPolicy::CONTROL_PLANE
    )
    repair = Step.create!(
      workflow: workflow,
      kind: "implement",
      position: 2,
      state: "succeeded",
      iteration: 2,
      loop_id: "grade-loop"
    )
    fresh_barrier = Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 3,
      state: "succeeded",
      iteration: 2,
      loop_id: "grade-loop",
      placement_policy: Step::PlacementPolicy::CONTROL_PLANE
    )
    tail = Step.create!(
      workflow: workflow,
      kind: "summarize",
      position: 4,
      state: "queued",
      depends_on_ids: [ stale_barrier.id ]
    )
    stale_barrier.update!(next_step: repair)
    repair.update!(next_step: fresh_barrier)
    fresh_barrier.update!(next_step: tail)

    result = described_class.call(workflow.id, tail.id)

    expect(result).to be_started
    expect(result.run.step).to eq(tail)
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

  it "does not resume queued workflows without WorkUnits" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", agent_provider: "codex")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "queued", agent_provider: "codex")
    Step.create!(workflow: workflow, kind: "prepare", position: 1)

    expect(StepDispatcher).not_to receive(:resume_deferred_phase)

    result = described_class.call(workflow.id)

    expect(result.status).to eq("unowned")
    expect(result.run).to be_nil
  end

  it "does not preserve replay-specific resume behavior without WorkUnits" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", agent_provider: "codex")
    workflow = Workflow.create!(job: job, trigger_kind: "replay", state: "queued", agent_provider: "codex")
    Step.create!(workflow: workflow, kind: "prepare", position: 1)

    expect(StepDispatcher).not_to receive(:resume_deferred_phase)

    result = described_class.call(workflow.id)

    expect(result.status).to eq("unowned")
    expect(result.run).to be_nil
  end
end
