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

  it "falls back to active workflows for legacy rows without work units" do
    job = Factories.job
    Workflow.create!(job: job, trigger_kind: "initial", state: "running")

    expect(described_class.active_job_ids([ job.id ])).to include(job.id)
    expect(described_class.active_trigger_kinds_by_job_id([ job.id ])).to eq(job.id => "initial")
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

  it "reports every active trigger kind from WorkUnit membership and legacy workflows" do
    job = Factories.job_record(issue_number: 151)
    workflow = Workflow.create!(job: job, trigger_kind: "pr_comment", state: "running")
    attach_work_unit(workflow, member_jobs: [ job ], kind: "pr_comment")
    attach_work_unit(nil, member_jobs: [ job ], kind: "ci_failure")
    Workflow.create!(job: job, trigger_kind: "manual", state: "queued")

    result = described_class.active_trigger_kind_lists_by_job_id([ job.id ])

    expect(result.keys).to eq([ job.id ])
    expect(result[job.id]).to contain_exactly("pr_comment", "ci_failure", "manual")
  end

  it "reports all active job ids from work unit membership and legacy workflows" do
    work_unit_job = Factories.job_record(issue_number: 201)
    legacy_job = Factories.job_record(repository: work_unit_job.repository, issue_number: 202)
    idle_job = Factories.job_record(repository: work_unit_job.repository, issue_number: 203)
    workflow = Workflow.create!(job: work_unit_job, trigger_kind: "manual", state: "succeeded")
    attach_work_unit(workflow, member_jobs: [ work_unit_job ], kind: "manual", state: "blocked")
    Workflow.create!(job: legacy_job, trigger_kind: "initial", state: "queued")

    expect(described_class.all_active_job_ids).to include(work_unit_job.id, legacy_job.id)
    expect(described_class.all_active_job_ids).not_to include(idle_job.id)
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
