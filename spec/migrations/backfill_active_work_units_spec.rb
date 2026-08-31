require "rails_helper"
require Rails.root.join("db/migrate/20260825123000_backfill_active_work_units")

RSpec.describe BackfillActiveWorkUnits, :ci_only do
  let(:migration) { described_class.new }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }

  it "creates intent, unit, member, and lock rows for an active workflow" do
    job.update!(branch_name: "syrus/job-#{job.id}")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago)

    migration.up

    unit = workflow.reload.work_unit
    expect(unit).to have_attributes(
      kind: "initial",
      state: "running",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      workflow: workflow,
      source_repository: repository,
      source_ref: job.branch_name,
      target_repository: repository,
      target_ref: repository.default_branch,
      started_at: workflow.started_at
    )
    expect(unit.work_intent).to have_attributes(
      kind: "initial",
      state: "requested",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      idempotency_key: "workflow:#{workflow.id}",
      source_type: "workflow_backfill",
      source_id: workflow.id,
      source_repository: repository,
      source_ref: job.branch_name,
      target_repository: repository,
      target_ref: repository.default_branch
    )
    expect(unit.work_unit_members.map { |member| [ member.job_id, member.role ] }).to eq([[ job.id, "primary" ]])
    expect(unit.work_unit_locks.pluck(:lock_key)).to eq([ "job:#{job.id}" ])
  end

  it "projects start-block artifacts onto the backfilled WorkUnit" do
    next_check_at = 10.minutes.from_now
    workflow = Workflow.create!(
      job: job,
      trigger_kind: "initial",
      state: "queued",
      artifacts: {
        "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
        "start_blocked_next_check_at" => next_check_at.iso8601,
        "start_blocked_details" => { "pressure" => "high" }
      }
    )

    migration.up

    unit = workflow.reload.work_unit
    expect(unit).to have_attributes(
      state: "blocked",
      blocked_reason: "admission_control",
      blocked_details: {
        "pressure" => "high",
        "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON
      }
    )
    expect(unit.blocked_until).to be_within(2.seconds).of(next_check_at)
    expect(WorkUnits::StartBlock.for(workflow.reload).reason).to eq("admission_control")
  end

  it "snapshots merge train members from merge train artifacts" do
    epic = Factories.epic(user: user, repository: repository)
    first = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 101)
    second = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 102)
    train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "main")
    MergeTrainMember.create!(merge_train: train, job: first, position: 0)
    MergeTrainMember.create!(merge_train: train, job: second, position: 1)
    workflow = Workflow.create!(
      job: second,
      trigger_kind: "merge_train",
      state: "running",
      artifacts: { "merge_train_id" => train.id }
    )

    migration.up

    unit = workflow.reload.work_unit
    expect(unit).to have_attributes(kind: "merge_train", scope_type: "epic", scope_id: epic.id)
    expect(unit.work_unit_members.order(:id).map { |member| [ member.job_id, member.role ] }).to eq(
      [[ first.id, "primary" ], [ second.id, "member" ]]
    )
    expect(unit.work_unit_locks.pluck(:lock_key)).to contain_exactly(
      "epic:#{epic.id}",
      "job:#{first.id}",
      "job:#{second.id}",
      "landing:repository:#{repository.id}"
    )
  end

  it "backfills epicless merge train workflows as job bundles" do
    first = Factories.job_record(user: user, repository: repository, issue_number: 101)
    second = Factories.job_record(user: user, repository: repository, issue_number: 102)
    train = MergeTrain.create!(repository: repository, base_branch: "main", priority: "medium")
    MergeTrainMember.create!(merge_train: train, job: first, position: 0)
    MergeTrainMember.create!(merge_train: train, job: second, position: 1)
    workflow = Workflow.create!(
      job: second,
      trigger_kind: "merge_train",
      state: "running",
      artifacts: { "merge_train_id" => train.id }
    )

    migration.up

    unit = workflow.reload.work_unit
    expect(unit).to have_attributes(kind: "job_bundle", scope_type: "repository", scope_id: repository.id)
    expect(unit.work_intent).to have_attributes(kind: "job_bundle", scope_type: "repository", scope_id: repository.id)
    expect(unit.work_unit_members.order(:id).map { |member| [ member.job_id, member.role ] }).to eq(
      [[ first.id, "primary" ], [ second.id, "member" ]]
    )
    expect(unit.work_unit_locks.pluck(:lock_key)).to contain_exactly(
      "job:#{first.id}",
      "job:#{second.id}",
      "repository:#{repository.id}",
      "landing:repository:#{repository.id}"
    )
  end
end
