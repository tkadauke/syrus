require "rails_helper"

RSpec.describe WorkUnits::Backfill do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "queued") }

  it "creates intent, unit, member, and lock rows for an active legacy workflow" do
    job.update!(branch_name: "syrus/job-#{job.id}")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago)

    result = described_class.workflow!(workflow)

    expect(result).to be_created
    unit = result.work_unit
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

  it "is idempotent for already backfilled workflows" do
    workflow = Workflow.create!(job: job, trigger_kind: "retry", state: "queued")

    first = described_class.workflow!(workflow)

    expect {
      second = described_class.workflow!(workflow.reload)
      expect(second).to be_skipped
      expect(second.skipped_reason).to eq("already_backfilled")
    }.not_to change { WorkUnit.count }
    expect(first.work_unit).to eq(workflow.reload.work_unit)
  end

  it "skips active workflows whose locks are already owned by another WorkUnit" do
    owner_workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)
    legacy_workflow = Workflow.create!(job: job, trigger_kind: "retry", state: "queued")

    result = described_class.workflow!(legacy_workflow)

    expect(result).to be_skipped
    expect(result.skipped_reason).to eq("active_lock_conflict")
    expect(legacy_workflow.reload.work_unit).to be_nil
    expect(owner_workflow.work_unit.work_unit_locks.pluck(:lock_key)).to contain_exactly("job:#{job.id}")
  end

  it "backfills active workflows and ignores terminal workflows by default" do
    active = Workflow.create!(job: job, trigger_kind: "initial", state: "queued")
    terminal = Workflow.create!(job: job, trigger_kind: "retry", state: "failed")

    results = described_class.active!

    expect(results.map(&:workflow)).to include(active)
    expect(terminal.reload.work_unit).to be_nil
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

    unit = described_class.workflow!(workflow).work_unit

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

    unit = described_class.workflow!(workflow).work_unit

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

  it "parents backfilled bundle validation units to the source landing unit" do
    source_workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running")
    parent = described_class.workflow!(source_workflow).work_unit
    first = Factories.job_record(user: user, repository: repository, issue_number: 101)
    second = Factories.job_record(user: user, repository: repository, issue_number: 102)
    validation = Workflow.create!(
      job: second,
      trigger_kind: "merge_train_validation",
      state: "running",
      artifacts: {
        "prefetch_landing_unit_kind" => "job_bundle",
        "prefetch_source_workflow_id" => source_workflow.id,
        "prefetch_merge_train_member_job_ids" => [ first.id, second.id ]
      }
    )

    unit = described_class.workflow!(validation).work_unit

    expect(unit).to have_attributes(
      kind: "job_bundle_validation",
      scope_type: "repository",
      scope_id: repository.id,
      parent_work_unit: parent
    )
    expect(unit.work_unit_members.order(:id).map { |member| [ member.job_id, member.role ] }).to eq(
      [[ first.id, "primary" ], [ second.id, "member" ]]
    )
  end
end
