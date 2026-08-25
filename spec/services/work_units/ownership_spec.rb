require "rails_helper"

RSpec.describe WorkUnits::Ownership do
  def attach_work_unit(workflow, member_jobs:, kind: workflow.trigger_kind, state: "running")
    primary = member_jobs.first
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: primary.repository,
      scope_type: primary.epic_id.present? ? "epic" : "job",
      scope_id: primary.epic_id.presence || primary.id,
      actor: primary.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: state,
      repository: primary.repository,
      scope_type: intent.scope_type,
      scope_id: intent.scope_id,
      workflow: workflow
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end

  it "ignores active legacy workflows for migrated paths without work units" do
    job = Factories.job_record
    Workflow.create!(job: job, trigger_kind: "initial", state: "running")

    expect(described_class.active_job_ids([ job.id ])).not_to include(job.id)
    expect(described_class.active_trigger_kinds_by_job_id([ job.id ])).to eq({})
  end

  it "preserves the replay legacy fallback while replay migrates separately" do
    job = Factories.job_record
    Workflow.create!(job: job, trigger_kind: "replay", state: "running")

    expect(described_class.active_job_ids([ job.id ])).to include(job.id)
    expect(described_class.active_trigger_kinds_by_job_id([ job.id ])).to eq(job.id => "replay")
    expect(described_class.active_trigger_kind_lists_by_job_id([ job.id ])).to eq(job.id => [ "replay" ])
  end

  it "centralizes replay-only start-block artifact fallback" do
    replay = Factories.job_record(issue_number: 31)
    migrated = Factories.job_record(repository: replay.repository, issue_number: 32)
    matching = Workflow.create!(
      job: replay,
      trigger_kind: "replay",
      state: "queued",
      artifacts: { "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON }
    )
    Workflow.create!(
      job: replay,
      trigger_kind: "replay",
      state: "queued",
      artifacts: { "start_blocked_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON }
    )
    Workflow.create!(
      job: migrated,
      trigger_kind: "initial",
      state: "queued",
      artifacts: { "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON }
    )

    result = described_class.legacy_replay_start_blocked_workflows_scope(
      [ replay.id, migrated.id ],
      reasons: StepDispatcher::ADMISSION_BLOCK_REASON
    )

    expect(result).to contain_exactly(matching)
  end

  it "can search replay start-block artifacts by migration-era patterns" do
    admission = Factories.job_record(issue_number: 33)
    resource = Factories.job_record(repository: admission.repository, issue_number: 34)
    Workflow.create!(
      job: admission,
      trigger_kind: "replay",
      state: "queued",
      artifacts: { "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON }
    )
    resource_workflow = Workflow.create!(
      job: resource,
      trigger_kind: "replay",
      state: "queued",
      artifacts: { "start_blocked_reason" => StepDispatcher::PAUSE_REASON_RESOURCE_SAFETY }
    )

    result = described_class.legacy_replay_start_blocked_workflows_scope(
      patterns: [ "%#{StepDispatcher::PAUSE_REASON_RESOURCE_SAFETY}%" ]
    )

    expect(result).to contain_exactly(resource_workflow)
  end

  it "separately searches unowned start-block artifacts during the WorkUnit migration" do
    replay = Factories.job_record(issue_number: 35)
    migrated = Factories.job_record(repository: replay.repository, issue_number: 36)
    Workflow.create!(
      job: replay,
      trigger_kind: "replay",
      state: "queued",
      artifacts: { "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON }
    )
    matching = Workflow.create!(
      job: migrated,
      trigger_kind: "initial",
      state: "queued",
      artifacts: { "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON }
    )
    workflow_with_unit = Workflow.create!(
      job: migrated,
      trigger_kind: "initial",
      state: "queued",
      artifacts: { "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON }
    )
    attach_work_unit(workflow_with_unit, member_jobs: [ migrated ], kind: "initial", state: "blocked")

    result = described_class.unowned_start_blocked_workflows_scope(
      [ replay.id, migrated.id ],
      reasons: StepDispatcher::ADMISSION_BLOCK_REASON
    )

    expect(result).to contain_exactly(matching)
  end

  it "ignores landing legacy workflow fallbacks after landing moves to work units" do
    job = Factories.job_record
    Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running")

    expect(described_class.active_job_ids([ job.id ], kinds: "auto_merge")).not_to include(job.id)
    expect(described_class.active_workflow_ids([ job.id ], kinds: "auto_merge")).to be_empty
  end

  it "derives migrated landing legacy exclusions from WorkDefinition policy" do
    auto_merge = Factories.job_record(issue_number: 421)
    bundle = Factories.job_record(repository: auto_merge.repository, issue_number: 422)
    validation = Factories.job_record(repository: auto_merge.repository, issue_number: 423)
    stack_rebase = Factories.job_record(repository: auto_merge.repository, issue_number: 424)
    manual = Factories.job_record(repository: auto_merge.repository, issue_number: 425)
    Workflow.create!(job: auto_merge, trigger_kind: "auto_merge", state: "running")
    Workflow.create!(job: bundle, trigger_kind: WorkDefinitions.for("job_bundle").workflow_trigger_kind, state: "running")
    Workflow.create!(job: validation, trigger_kind: WorkDefinitions.for("job_bundle_validation").workflow_trigger_kind, state: "running")
    Workflow.create!(job: stack_rebase, trigger_kind: "stack_rebase", state: "running")
    Workflow.create!(job: manual, trigger_kind: "manual", state: "running")

    ids = [ auto_merge.id, bundle.id, validation.id, stack_rebase.id, manual.id ]

    expect(described_class.active_job_ids(ids)).to be_empty
  end

  it "uses work unit membership to report active epic-wide work on member jobs" do
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 101)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 102)
    workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
    attach_work_unit(workflow, member_jobs: [ first, second ], kind: "merge_train")

    expect(described_class.active_job_ids([ second.id ])).to include(second.id)
    expect(described_class.active_trigger_kinds_by_job_id([ second.id ])).to eq(second.id => "merge_train")
  end

  it "reports every active trigger kind from WorkUnit membership and replay legacy workflows" do
    job = Factories.job_record(issue_number: 151)
    workflow = Workflow.create!(job: job, trigger_kind: "pr_comment", state: "running")
    attach_work_unit(workflow, member_jobs: [ job ], kind: "pr_comment")
    attach_work_unit(nil, member_jobs: [ job ], kind: "ci_failure")
    Workflow.create!(job: job, trigger_kind: "replay", state: "queued")

    result = described_class.active_trigger_kind_lists_by_job_id([ job.id ])

    expect(result.keys).to eq([ job.id ])
    expect(result[job.id]).to contain_exactly("pr_comment", "ci_failure", "replay")
  end

  it "reports all active job ids from work unit membership and replay legacy workflows" do
    work_unit_job = Factories.job_record(issue_number: 201)
    legacy_job = Factories.job_record(repository: work_unit_job.repository, issue_number: 202)
    idle_job = Factories.job_record(repository: work_unit_job.repository, issue_number: 203)
    workflow = Workflow.create!(job: work_unit_job, trigger_kind: "manual", state: "succeeded")
    attach_work_unit(workflow, member_jobs: [ work_unit_job ], kind: "manual", state: "blocked")
    Workflow.create!(job: legacy_job, trigger_kind: "replay", state: "queued")

    expect(described_class.all_active_job_ids).to include(work_unit_job.id, legacy_job.id)
    expect(described_class.all_active_job_ids).not_to include(idle_job.id)
  end

  it "reports active workflow ids from work units and replay legacy workflows" do
    work_unit_job = Factories.job_record(issue_number: 211)
    legacy_job = Factories.job_record(repository: work_unit_job.repository, issue_number: 212)
    terminal_workflow = Workflow.create!(
      job: work_unit_job,
      trigger_kind: "manual",
      agent_provider: "codex",
      state: "succeeded"
    )
    legacy_workflow = Workflow.create!(
      job: legacy_job,
      trigger_kind: "replay",
      agent_provider: "codex",
      state: "queued"
    )
    ignored_workflow = Workflow.create!(
      job: work_unit_job,
      trigger_kind: "retry",
      agent_provider: "claude",
      state: "queued"
    )
    attach_work_unit(terminal_workflow, member_jobs: [ work_unit_job ], kind: "manual", state: "running")

    expect(described_class.active_workflow_ids(agent_provider: "codex")).to contain_exactly(terminal_workflow.id, legacy_workflow.id)
    expect(described_class.active_workflow_ids([ work_unit_job.id ], kinds: "manual")).to contain_exactly(terminal_workflow.id)
    expect(described_class.active_workflow_ids(agent_provider: "codex")).not_to include(ignored_workflow.id)
  end

  it "reports the active workflow for each member job" do
    primary = Factories.job_record(issue_number: 221)
    member = Factories.job_record(repository: primary.repository, user: primary.user, issue_number: 222)
    workflow = Workflow.create!(
      job: primary,
      trigger_kind: "merge_train",
      agent_provider: "codex",
      state: "running"
    )
    attach_work_unit(workflow, member_jobs: [ primary, member ], kind: "merge_train")

    result = described_class.active_workflows_by_job_id([ member.id ], agent_provider: "codex")

    expect(result).to eq(member.id => workflow)
  end

  it "prefers running active units over newer blocked attempts" do
    job = Factories.job_record(issue_number: 225)
    running_workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "running")
    blocked_workflow = Workflow.create!(job: job, trigger_kind: "rebase", state: "queued")
    running_unit = attach_work_unit(running_workflow, member_jobs: [ job ], kind: "ci_failure", state: "running")
    blocked_unit = attach_work_unit(blocked_workflow, member_jobs: [ job ], kind: "rebase", state: "blocked")
    blocked_unit.update!(created_at: 5.minutes.from_now)

    expect(described_class.active_units_by_job_id([ job.id ])).to eq(job.id => running_unit)
    expect(described_class.active_workflows_by_job_id([ job.id ])).to eq(job.id => running_workflow)
    expect(described_class.active_trigger_kinds_by_job_id([ job.id ])).to eq(job.id => "ci_failure")
  end

  it "does not fall back to migrated legacy workflows when no active work unit owns the job" do
    job = Factories.job_record(issue_number: 223)
    Workflow.create!(
      job: job,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "queued"
    )

    expect(described_class.active_workflows_by_job_id([ job.id ], agent_provider: "claude")).to eq({})
    expect(described_class.active_workflows_by_job_id([ job.id ], agent_provider: "codex")).to eq({})
  end

  it "filters active membership by work unit kind" do
    job = Factories.job
    retry_workflow = Workflow.create!(job: job, trigger_kind: "retry", state: "running")
    feedback = Workflow.create!(job: job, trigger_kind: "chat_feedback", state: "running")
    attach_work_unit(retry_workflow, member_jobs: [ job ], kind: "retry")
    attach_work_unit(feedback, member_jobs: [ job ], kind: "chat_feedback")

    expect(described_class.active_for_job_kind?(job, "retry")).to be true
    expect(described_class.active_for_job_kind?(job, "merge_train")).to be false
    expect(described_class.active_units_by_job_id([ job.id ], kinds: "chat_feedback")[job.id].workflow).to eq(feedback)
  end

  it "reports active epic scoped units" do
    epic = Factories.epic
    job = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 101)
    workflow = Workflow.create!(job: job, trigger_kind: "merge_train", state: "running")
    attach_work_unit(workflow, member_jobs: [ job ], kind: "merge_train")

    expect(described_class.active_for_epic?(epic, kinds: "merge_train")).to be true
    expect(described_class.active_for_epic?(epic, kinds: "retry")).to be false
  end

  it "reports active units by persisted lock key" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running")
    unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "auto_merge")
    unit.work_unit_locks.create!(lock_key: "landing:repository:#{job.repository_id}")

    expect(described_class.active_for_lock_key?("landing:repository:#{job.repository_id}")).to be true
    expect(described_class.active_unit_for_lock_key("landing:repository:#{job.repository_id}")).to eq(unit)
  end

  it "reports blocked job ids while excluding landing units by default" do
    blocked = Factories.job_record(issue_number: 301)
    landing = Factories.job_record(repository: blocked.repository, issue_number: 302)
    blocked_workflow = Workflow.create!(job: blocked, trigger_kind: "initial", state: "running")
    landing_workflow = Workflow.create!(job: landing, trigger_kind: "auto_merge", state: "running")
    attach_work_unit(blocked_workflow, member_jobs: [ blocked ], kind: "initial", state: "blocked")
    attach_work_unit(landing_workflow, member_jobs: [ landing ], kind: "auto_merge", state: "blocked")

    expect(described_class.all_blocked_job_ids).to include(blocked.id)
    expect(described_class.all_blocked_job_ids).not_to include(landing.id)
    expect(described_class.all_blocked_job_ids(include_landing: true)).to include(blocked.id, landing.id)
  end

  it "returns blocked metadata keyed by job id" do
    job = Factories.job_record(issue_number: 303)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
    unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "initial", state: "blocked")
    blocked_until = 10.minutes.from_now
    unit.update!(
      blocked_reason: "admission_control",
      blocked_until: blocked_until,
      blocked_details: { "reason" => "worker_host_pressure_high" }
    )

    data = described_class.blocked_data_by_job_id([ job.id ]).fetch(job.id)

    expect(data).to include(
      reason: "admission_control",
      next_check_at: blocked_until.iso8601,
      count: nil,
      details: { "reason" => "worker_host_pressure_high" }
    )
    expect(data.fetch(:at)).to be_present
  end

  it "filters active lock ownership by kind" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running")
    unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "auto_merge")
    unit.work_unit_locks.create!(lock_key: "job:#{job.id}")

    expect(described_class.active_for_lock_key?("job:#{job.id}", kinds: "auto_merge")).to be true
    expect(described_class.active_for_lock_key?("job:#{job.id}", kinds: "merge_train")).to be false
  end

  it "reports active work units whose definitions block CI repair" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running")
    unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "auto_merge")

    expect(described_class.active_ci_failure_blocking_unit_for_job(job)).to eq(unit)
    expect(described_class.ci_failure_blocked_for_job?(job)).to be true
  end

  it "does not treat ordinary job work as a CI repair blocker" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "retry", state: "running")
    attach_work_unit(workflow, member_jobs: [ job ], kind: "retry")

    expect(described_class.active_ci_failure_blocking_unit_for_job(job)).to be_nil
    expect(described_class.ci_failure_blocked_for_job?(job)).to be false
  end

  it "blocks CI repair for epic-wide units on member jobs" do
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 101)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 102)
    workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
    unit = attach_work_unit(workflow, member_jobs: [ first, second ], kind: "merge_train")

    expect(described_class.active_ci_failure_blocking_unit_for_job(second)).to eq(unit)
    expect(described_class.ci_failure_blocked_for_job?(second)).to be true
  end

  it "ignores released locks and terminal units" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running")
    unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "auto_merge")
    lock = unit.work_unit_locks.create!(lock_key: "job:#{job.id}")

    expect(described_class.active_for_lock_key?("job:#{job.id}")).to be true

    lock.release!
    expect(described_class.active_for_lock_key?("job:#{job.id}")).to be false

    unit.work_unit_locks.create!(lock_key: "job:#{job.id}")
    unit.mark_terminal!("cancelled")
    expect(described_class.active_for_lock_key?("job:#{job.id}")).to be false
  end

  it "prefers work unit ownership over stale direct workflow fallback" do
    job = Factories.job
    legacy = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
    active = Workflow.create!(job: job, trigger_kind: "chat_feedback", state: "running")
    attach_work_unit(active, member_jobs: [ job ], kind: "chat_feedback")
    legacy.update!(created_at: 1.minute.from_now)

    expect(described_class.active_trigger_kinds_by_job_id([ job.id ])).to eq(job.id => "chat_feedback")
  end
end
