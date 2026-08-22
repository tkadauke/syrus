require "rails_helper"

RSpec.describe WorkUnits::Launcher do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

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

  it "creates a fresh intent and unit for repeated non-idempotent launches" do
    first = described_class.instantiate(kind: "manual_visual_review", job: job)
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

  it "passes workflow-specific options through to specialized templates" do
    workflow = described_class.instantiate(
      kind: "rebase",
      job: job,
      base_branch: "syrus/parent"
    )

    expect(workflow.trigger_kind).to eq("rebase")
    expect(workflow.artifact(RebaseTarget::BASE_BRANCH_ARTIFACT)).to eq("syrus/parent")
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
    expect(result.run).to be_queued
    expect(result.run.step).to eq(workflow.first_step)
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
end
