require "rails_helper"

RSpec.describe WorkEngine::RuntimeOwnership do
  def set_reconciler_gate(enabled)
    Feature.find_or_create_by!(slug: "work_units_reconciler") do |feature|
      feature.category = "Operations"
      feature.name = "Work units reconciler"
    end.update!(enabled: enabled)
  end

  def set_landing_gate(enabled)
    Feature.find_or_create_by!(slug: "work_units_landing") do |feature|
      feature.category = "Operations"
      feature.name = "Work units landing"
    end.update!(enabled: enabled)
  end

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

  it "uses legacy active epic-wide workflow detection when the reconciler gate is disabled" do
    set_reconciler_gate(false)
    epic = Factories.epic
    job = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    Workflow.create!(job: job, trigger_kind: "merge_train", state: "running")

    expect(described_class.active_epic_wide_workflow_for_job?(job)).to be true
  end

  it "uses work unit epic ownership when the reconciler gate is enabled" do
    set_reconciler_gate(true)
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: "succeeded")
    attach_epic_unit(epic, workflow, member_jobs: [ first, second ])

    expect(described_class.active_epic_wide_workflow_for_job?(second)).to be true
  end

  it "ignores work unit epic ownership while the reconciler gate is disabled" do
    set_reconciler_gate(false)
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: "succeeded")
    attach_epic_unit(epic, workflow, member_jobs: [ first, second ])

    expect(described_class.active_epic_wide_workflow_for_job?(second)).to be false
  end

  it "uses legacy active landing workflow detection when the landing gate is disabled" do
    set_landing_gate(false)
    job = Factories.job_record
    Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running")

    expect(described_class.active_landing_work_for_job?(job)).to be true
  end

  it "uses work unit landing ownership when the landing gate is enabled" do
    set_landing_gate(true)
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "succeeded")
    attach_landing_unit(job, workflow: workflow, state: "blocked")

    expect(described_class.active_landing_work_for_job?(job)).to be true
  end

  it "ignores non-landing work units when checking landing ownership" do
    set_landing_gate(true)
    job = Factories.job_record
    attach_landing_unit(job, kind: "initial", state: "running")

    expect(described_class.active_landing_work_for_job?(job)).to be false
  end
end
