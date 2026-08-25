require "rails_helper"

RSpec.describe WorkEngine::RuntimeOwnership do
  def attach_epic_unit(epic, workflow, member_jobs:, state: "running")
    intent = WorkIntent.create!(
      kind: "merge_train",
      state: "requested",
      repository: epic.repository,
      scope_type: "epic",
      scope_id: epic.id,
      actor: epic.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: "merge_train",
      state: state,
      repository: epic.repository,
      scope_type: "epic",
      scope_id: epic.id,
      workflow: workflow
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end

  def attach_landing_unit(job, workflow: nil, kind: "auto_merge", state: "running")
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      actor: job.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: state,
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      workflow: workflow
    )
    unit.work_unit_members.create!(job: job, role: "primary")
    unit
  end

  it "uses WorkUnit epic ownership" do
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: "succeeded")
    attach_epic_unit(epic, workflow, member_jobs: [ first, second ])

    expect(described_class.active_epic_wide_workflow_for_job?(second)).to be true
  end

  it "ignores legacy active epic-wide workflows without WorkUnit ownership" do
    epic = Factories.epic
    job = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    Workflow.create!(job: job, trigger_kind: "merge_train", state: "running")

    expect(described_class.active_epic_wide_workflow_for_job?(job)).to be false
  end

  it "does not treat non-landing active workflows as legacy landing ownership" do
    job = Factories.job_record
    Workflow.create!(job: job, trigger_kind: "initial", state: "running")

    expect(described_class.active_landing_work_for_job?(job)).to be false
  end

  it "uses WorkUnit landing ownership" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "succeeded")
    attach_landing_unit(job, workflow: workflow, state: "blocked")

    expect(described_class.active_landing_work_for_job?(job)).to be true
  end

  it "ignores non-landing work units when checking landing ownership" do
    job = Factories.job_record
    attach_landing_unit(job, kind: "initial", state: "running")

    expect(described_class.active_landing_work_for_job?(job)).to be false
  end
end
