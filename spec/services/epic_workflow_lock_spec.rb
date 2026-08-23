require "rails_helper"

RSpec.describe EpicWorkflowLock do
  def set_reconciler_gate(enabled)
    Feature.find_or_create_by!(slug: "work_units_reconciler") do |feature|
      feature.category = "Operations"
      feature.name = "Work units reconciler"
    end.update!(enabled: enabled)
  end

  def attach_epic_unit(epic, workflow, member_jobs:)
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
      state: "running",
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

  it "uses legacy Epic-wide workflows while the reconciler path is legacy-owned" do
    set_reconciler_gate(false)
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    blocker = Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
    candidate = Workflow.create!(job: second, trigger_kind: "initial", state: "queued")

    expect(described_class.blocking_workflow_for(candidate)).to eq(blocker)
  end

  it "ignores legacy Epic-wide workflows when the reconciler path is WorkUnit-owned" do
    set_reconciler_gate(true)
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
    candidate = Workflow.create!(job: second, trigger_kind: "initial", state: "queued")

    expect(described_class.blocking_workflow_for(candidate)).to be_nil
  end

  it "uses Epic WorkUnit ownership when the reconciler path is WorkUnit-owned" do
    set_reconciler_gate(true)
    epic = Factories.epic
    first = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 1)
    second = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic, issue_number: 2)
    blocker = Workflow.create!(job: first, trigger_kind: "merge_train", state: "succeeded")
    attach_epic_unit(epic, blocker, member_jobs: [ first, second ])
    candidate = Workflow.create!(job: second, trigger_kind: "initial", state: "queued")

    expect(described_class.blocking_workflow_for(candidate)).to eq(blocker)
  end
end
