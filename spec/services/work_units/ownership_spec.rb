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

  it "prefers work unit ownership over stale direct workflow fallback" do
    job = Factories.job
    legacy = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
    active = Workflow.create!(job: job, trigger_kind: "chat_feedback", state: "running")
    attach_work_unit(active, member_jobs: [ job ], kind: "chat_feedback")
    legacy.update!(created_at: 1.minute.from_now)

    expect(described_class.active_trigger_kinds_by_job_id([ job.id ])).to eq(job.id => "chat_feedback")
  end
end
