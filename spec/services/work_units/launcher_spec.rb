require "rails_helper"

RSpec.describe WorkUnits::Launcher do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  before { clear_enqueued_jobs }
  after { clear_enqueued_jobs }

  def set_scheduler_gate(enabled)
    Feature.find_or_create_by!(slug: "work_units_scheduler") do |feature|
      feature.category = "Operations"
      feature.name = "Work units scheduler"
    end.update!(enabled: enabled)
  end

  it "instantiates the workflow template declared by the work definition" do
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)

    expect(workflow).to be_persisted
    expect(workflow).to have_attributes(job: job, trigger_kind: "manual_visual_review")
    expect(workflow.steps.pluck(:kind)).to eq(%w[prepare visual_review])
  end

  it "creates a shadow work intent and unit for the workflow attempt" do
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)
    unit = workflow.work_unit
    intent = unit.work_intent

    expect(intent).to have_attributes(
      kind: "manual_visual_review",
      state: "requested",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      priority: job.priority,
      actor: user,
      source_type: "workflow_launch"
    )
    expect(unit).to have_attributes(
      kind: "manual_visual_review",
      state: "queued",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      workflow: workflow
    )
    expect(unit.work_unit_members.map { |member| [ member.job_id, member.role ] }).to eq([[ job.id, "primary" ]])
    expect(unit.work_unit_locks.pluck(:lock_key)).to contain_exactly("job:#{job.id}")
  end

  it "creates shadow ownership for normal initial jobs" do
    workflow = described_class.instantiate(kind: "initial", job: job)

    expect(workflow.work_unit).to have_attributes(kind: "initial", scope_type: "job", scope_id: job.id)
    expect(workflow.work_unit.work_intent).to have_attributes(kind: "initial", scope_type: "job", scope_id: job.id)
  end

  it "allows repeated non-idempotent launches while locks are shadow-only" do
    first = described_class.instantiate(kind: "manual_visual_review", job: job)

    second = described_class.instantiate(kind: "manual_visual_review", job: job)

    expect(second).not_to eq(first)
    expect(WorkUnit.where(kind: "manual_visual_review", scope_type: "job", scope_id: job.id).count).to eq(2)
    expect(first.work_unit).to be_active
    expect(second.work_unit.work_unit_locks.active).to be_empty
  end

  it "prevents repeated non-idempotent launches when the scheduler gate owns job work" do
    set_scheduler_gate(true)
    first = described_class.instantiate(kind: "manual_visual_review", job: job)

    expect {
      described_class.instantiate(kind: "manual_visual_review", job: job)
    }.to raise_error(WorkUnits::Launcher::LockConflict, /#{Regexp.escape("job:#{job.id}")}/)
    expect(WorkUnit.where(kind: "manual_visual_review", scope_type: "job", scope_id: job.id).count).to eq(1)
    expect(first.work_unit).to be_active
  end

  it "creates a fresh intent and unit for repeated non-idempotent launches after the first unit is terminal" do
    first = described_class.instantiate(kind: "manual_visual_review", job: job)
    first.work_unit.mark_terminal!("cancelled")

    second = described_class.instantiate(kind: "manual_visual_review", job: job)

    expect(second).not_to eq(first)
    expect(second.work_unit).not_to eq(first.work_unit)
    expect(second.work_unit.work_intent).not_to eq(first.work_unit.work_intent)
  end

  it "reuses the active workflow for an idempotent launch" do
    first = described_class.instantiate(kind: "manual_visual_review", job: job, idempotency_key: "manual-visual-review:#{job.id}")
    second = described_class.instantiate(kind: "manual_visual_review", job: job, idempotency_key: "manual-visual-review:#{job.id}")

    expect(second).to eq(first)
    expect(WorkIntent.where(idempotency_key: "manual-visual-review:#{job.id}").count).to eq(1)
    expect(first.work_unit.work_intent.work_units.count).to eq(1)
  end

  it "creates a new unit for the same idempotent intent after the prior unit is terminal" do
    first = described_class.instantiate(kind: "manual_visual_review", job: job, idempotency_key: "manual-visual-review:#{job.id}")
    first.work_unit.mark_terminal!("failed")

    second = described_class.instantiate(kind: "manual_visual_review", job: job, idempotency_key: "manual-visual-review:#{job.id}")

    expect(second).not_to eq(first)
    expect(second.work_unit.work_intent).to eq(first.work_unit.work_intent)
    expect(second.work_unit).not_to eq(first.work_unit)
  end

  it "passes artifacts and agent provider through to the workflow template" do
    workflow = described_class.instantiate(
      kind: "ci_failure",
      job: job,
      artifacts: { "head_sha" => "abc123" },
      agent_provider: "codex"
    )

    expect(workflow.trigger_kind).to eq("ci_failure")
    expect(workflow.agent_provider).to eq("codex")
    expect(workflow.artifact("head_sha")).to eq("abc123")
  end

  it "snapshots launch artifacts on the work intent for later relaunches" do
    workflow = described_class.instantiate(
      kind: "ci_failure",
      job: job,
      artifacts: { "head_sha" => "abc123", "base_sha" => "base456" }
    )

    expect(workflow.work_unit.work_intent.payload_artifacts).to include(
      "head_sha" => "abc123",
      "base_sha" => "base456"
    )
  end

  it "uses work intent payload artifacts when relaunching an intent" do
    workflow = described_class.instantiate(
      kind: "ci_failure",
      job: job,
      artifacts: { "head_sha" => "abc123", "base_sha" => "base456" },
      idempotency_key: "ci-failure:#{job.id}:abc123"
    )
    intent = workflow.work_unit.work_intent
    workflow.work_unit.mark_terminal!("failed")

    relaunched = described_class.instantiate_intent!(intent)

    expect(relaunched).not_to eq(workflow)
    expect(relaunched.artifact("head_sha")).to eq("abc123")
    expect(relaunched.artifact("base_sha")).to eq("base456")
  end

  it "passes workflow-specific options through to specialized templates" do
    workflow = described_class.instantiate(
      kind: "rebase",
      job: job,
      base_branch: "syrus/parent"
    )

    expect(workflow.trigger_kind).to eq("rebase")
    expect(workflow.artifact(RebaseTarget::BASE_BRANCH_ARTIFACT)).to eq("syrus/parent")
  end

  it "uses maintenance-scoped locks for rebase workflows so they can recover active job work" do
    active = described_class.instantiate(kind: "initial", job: job)

    rebase = described_class.instantiate(kind: "rebase", job: job, base_branch: "main")

    expect(active.work_unit.work_unit_locks.pluck(:lock_key)).to include("job:#{job.id}")
    expect(rebase.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly("maintenance:rebase:job:#{job.id}")
  end

  it "preempts active CI repair when a rebase starts for the same job" do
    ci_repair = described_class.instantiate(
      kind: "ci_failure",
      job: job,
      artifacts: { "head_sha" => "head123", "base_sha" => "base123" }
    )
    ci_repair.update!(state: "running")
    ci_repair.work_unit.update!(state: "running")

    rebase = described_class.instantiate(kind: "rebase", job: job, base_branch: "main")

    expect(ci_repair.reload).to be_cancelled
    expect(ci_repair.artifact("cancelled_reason")).to eq(Workflow::SUPERSEDED_BY_REBASE_REASON)
    expect(ci_repair.artifact("preemption_reason")).to eq("superseded_by_rebase")
    expect(ci_repair.work_unit.reload).to have_attributes(
      state: "cancelled",
      preemption_reason: "superseded_by_rebase",
      preempted_by_work_unit: rebase.work_unit
    )
  end

  it "snapshots known ref metadata onto the intent and unit" do
    job.update!(branch_name: "syrus/job-#{job.id}")

    workflow = described_class.instantiate(
      kind: "rebase",
      job: job,
      artifacts: { "delivery_track" => "default" },
      base_branch: "syrus/parent"
    )
    unit = workflow.work_unit
    intent = unit.work_intent

    expect(intent).to have_attributes(
      delivery_track: "default",
      source_repository: repository,
      source_remote_kind: "repository",
      source_ref: job.branch_name,
      target_repository: repository,
      target_remote_kind: "repository",
      target_ref: "syrus/parent"
    )
    expect(unit).to have_attributes(
      delivery_track: "default",
      source_repository: repository,
      source_remote_kind: "repository",
      source_ref: job.branch_name,
      target_repository: repository,
      target_remote_kind: "repository",
      target_ref: "syrus/parent"
    )
  end

  it "can use a specialized template while recording an existing workflow trigger kind" do
    workflow = described_class.instantiate(
      kind: "checkpoint_resume",
      job: job,
      artifacts: { "checkpoint_resume_steps" => %w[prepare summarize] }
    )

    expect(workflow.trigger_kind).to eq("retry")
    expect(workflow.work_unit.kind).to eq("checkpoint_resume")
    expect(workflow.steps.pluck(:kind)).to eq(%w[prepare summarize])
  end

  it "can create and start a workflow through the same funnel" do
    result = described_class.create_and_start!(kind: "manual_visual_review", job: job)

    expect(result.workflow).to be_persisted
    expect(result.workflow.work_unit).to have_attributes(kind: "manual_visual_review")
    expect(result).to be_started
    expect(result.intent).to eq(result.workflow.work_unit.work_intent)
    expect(result.work_unit).to eq(result.workflow.work_unit)
    expect(result.run).to be_queued
    expect(result.run.step).to eq(result.workflow.first_step)
  end

  it "runs a callback after workflow creation and before dispatch" do
    state = []
    allow(StepDispatcher).to receive(:start_workflow) do |workflow|
      state << [ :start, workflow.id ]
      workflow.first_step.runs.last
    end

    result = described_class.create_and_start!(
      kind: "manual_visual_review",
      job: job,
      before_start: ->(workflow) { state << [ :before_start, workflow.id ] }
    )

    expect(result.workflow).to be_persisted
    expect(state).to eq([
      [ :before_start, result.workflow.id ],
      [ :start, result.workflow.id ]
    ])
  end

  it "can start an existing workflow through the launcher boundary" do
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)

    result = described_class.start!(workflow)

    expect(result.workflow).to eq(workflow)
    expect(result).to be_started
    expect(result.run).to be_queued
    expect(result.run.step).to eq(workflow.first_step)
  end

  it "lets the work unit scheduler block a start before the first Run is created" do
    set_scheduler_gate(true)
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)
    workflow.work_unit.request_pause!

    expect {
      @result = described_class.start!(workflow)
    }.not_to change { Run.count }

    expect(@result).to be_blocked
    expect(@result.workflow).to eq(workflow)
    expect(@result.run).to be_nil
    expect(@result.reason).to eq("manual_pause")
    expect(@result.work_unit.reload).to have_attributes(state: "blocked", blocked_reason: "manual_pause")
  ensure
    set_scheduler_gate(false)
  end

  it "schedules a recheck when a runtime gate blocks the launch" do
    set_scheduler_gate(true)
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)
    retry_at = 12.minutes.from_now
    gate_result = WorkUnits::GateResult.block(
      reason: WorkUnits::Gates::ProviderAvailability::REASON,
      retry_at: retry_at,
      details: { "provider" => "codex" }
    )
    allow(WorkUnits::Scheduler).to receive(:evaluate!).with(workflow.work_unit).and_return(gate_result)

    expect {
      @result = described_class.start!(workflow)
    }.not_to change { Run.count }

    expect(@result).to be_blocked
    expect(enqueued_jobs.select { |entry| entry[:job] == WorkflowPhaseAdmissionJob }.last[:at]).to be_within(2.seconds).of(retry_at.to_f)
  ensure
    set_scheduler_gate(false)
  end

  it "does not schedule automatic rechecks for manual pauses" do
    set_scheduler_gate(true)
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)
    gate_result = WorkUnits::GateResult.block(
      reason: WorkUnits::Gates::ManualPause::REASON,
      details: { "pause_requested" => true }
    )
    allow(WorkUnits::Scheduler).to receive(:evaluate!).with(workflow.work_unit).and_return(gate_result)

    described_class.start!(workflow)

    expect(enqueued_jobs.map { |entry| entry[:job] }).not_to include(WorkflowPhaseAdmissionJob)
  ensure
    set_scheduler_gate(false)
  end

  it "snapshots merge train members from the merge train artifact" do
    epic = Factories.epic(user: user, repository: repository)
    first = Factories.job_record(user: user, repository: repository, epic: epic)
    second = Factories.job_record(user: user, repository: repository, epic: epic)
    train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "main")
    MergeTrainMember.create!(merge_train: train, job: first, position: 0)
    MergeTrainMember.create!(merge_train: train, job: second, position: 1)

    workflow = described_class.instantiate(
      kind: "merge_train",
      job: second,
      artifacts: { "merge_train_id" => train.id }
    )

    expect(workflow.work_unit.work_unit_members.order(:id).map { |member| [ member.job_id, member.role ] }).to eq(
      [[ first.id, "primary" ], [ second.id, "member" ]]
    )
    expect(workflow.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly(
      "epic:#{epic.id}",
      "job:#{first.id}",
      "job:#{second.id}",
      "landing:repository:#{repository.id}"
    )
  end

  it "uses maintenance-scoped locks for stack rebase workflows" do
    epic = Factories.epic(user: user, repository: repository)
    parent = Factories.job_record(user: user, repository: repository, epic: epic)
    child = Factories.job_record(user: user, repository: repository, epic: epic, parent_job: parent)

    workflow = described_class.instantiate(kind: "stack_rebase", job: child, base_branch: parent.branch_name || "main")

    expect(workflow.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly(
      "maintenance:rebase:job:#{child.id}",
      "maintenance:stack_rebase:epic:#{epic.id}"
    )
  end
end
