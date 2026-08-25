require "rails_helper"

RSpec.describe WorkIntents::JobWakeup do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  it "marks current intents waiting instead of starting queued workflows when dependencies are unsatisfied" do
    blocker = Factories.job_record(user: user, repository: repository, state: "queued")
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    JobDependency.create!(job: job, depends_on_job: blocker, source: "manual")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)

    expect {
      result = described_class.call(job)
      expect(result).to be(false)
    }.not_to change { Run.count }

    expect(workflow.work_unit.work_intent.reload).to have_attributes(
      state: "waiting",
      wait_reason: "dependency"
    )
    expect(workflow.first_step.runs).to be_empty
  end

  it "marks persisted job intents waiting even when no workflow has been instantiated yet" do
    blocker = Factories.job_record(user: user, repository: repository, state: "queued")
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    JobDependency.create!(job: job, depends_on_job: blocker, source: "manual")
    intent = WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      actor: user,
      source_type: "spec"
    )

    expect {
      result = described_class.call(job)
      expect(result).to be(false)
    }.not_to change { WorkUnit.count }

    expect(intent.reload).to have_attributes(state: "waiting", wait_reason: "dependency")
  end

  it "clears a managed dependency wait and starts queued workflows once the intent is ready" do
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    intent = workflow.work_unit.work_intent
    intent.wait!(reason: "dependency", details: { "blocked_by_job_ids" => [ 123 ] })

    expect {
      result = described_class.call(job)
      expect(result).to be(true)
    }.to change { Run.count }.by(1)

    expect(intent.reload).to have_attributes(state: "requested", wait_reason: nil)
    expect(workflow.first_step.runs.last).to be_queued
  end

  it "launches a persisted job intent once dependencies become ready" do
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    intent = WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: repository,
      scope_type: "job",
      scope_id: job.id,
      actor: user,
      source_type: "spec"
    )
    intent.wait!(reason: "dependency", details: { "blocked_by_job_ids" => [ 123 ] })

    expect {
      result = described_class.call(job)
      expect(result).to be(true)
    }.to change { WorkUnit.count }.by(1)
      .and change { Workflow.count }.by(1)
      .and change { Run.count }.by(1)

    unit = intent.reload.work_units.first
    expect(intent).to have_attributes(state: "requested", wait_reason: nil)
    expect(unit).to have_attributes(kind: "initial", state: "queued")
    expect(unit.workflow.first_step.runs.last).to be_queued
  end

  it "uses execution dependency semantics so stack children can start before parent merge" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    parent = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      state: "implemented",
      branch_name: "syrus/parent",
      pr_number: 44
    )
    parent.runs.create!(trigger_kind: "initial", agent_provider: parent.agent_provider, head_sha: "a" * 40)
    child = Factories.job_record(user: user, repository: repository, epic: epic, state: "queued")
    JobDependency.create!(job: child, depends_on_job: parent, source: "manual")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: child)

    expect {
      result = described_class.call(child)
      expect(result).to be(true)
    }.to change { workflow.first_step.runs.reload.count }.by(1)

    expect(workflow.work_unit.work_intent.reload).to have_attributes(state: "requested", wait_reason: nil)
  end

  it "does not start normal queued workflows that do not have WorkUnit ownership" do
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    workflow = Workflows::Initial.instantiate(job: job)

    expect {
      result = described_class.call(job)
      expect(result).to be(false)
    }.not_to change { workflow.first_step.runs.reload.count }
  end

  it "still starts replay queued workflows that do not have WorkUnit ownership yet" do
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    workflow = Workflow.create!(job: job, trigger_kind: "replay", state: "queued", agent_provider: job.agent_provider)
    Step.create!(workflow: workflow, kind: "prepare", position: 0)

    expect {
      result = described_class.call(job)
      expect(result).to be(true)
    }.to change { workflow.first_step.runs.reload.count }.by(1)
  end

  it "starts queued workflows discovered through WorkUnit membership" do
    owner = Factories.job_record(user: user, repository: repository, state: "queued", issue_number: 31)
    member = Factories.job_record(user: user, repository: repository, state: "queued", issue_number: 32)
    workflow = Workflows::Initial.instantiate(job: owner)
    intent = WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: repository,
      scope_type: "job",
      scope_id: owner.id,
      actor: user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: "initial",
      state: "queued",
      repository: repository,
      scope_type: "job",
      scope_id: owner.id,
      workflow: workflow
    )
    unit.work_unit_members.create!(job: owner, role: "primary")
    unit.work_unit_members.create!(job: member, role: "member")

    expect {
      result = described_class.call(member)
      expect(result).to be(true)
    }.to change { workflow.first_step.runs.reload.count }.by(1)

    expect(workflow.first_step.runs.last).to be_queued
    expect(unit.reload).to be_queued
  end

  it "releases an epic block and starts queued workflows when execution dependencies become ready" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    prerequisite = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      state: "implemented",
      branch_name: "syrus/parent",
      pr_number: 44
    )
    job = Factories.job_record(user: user, repository: repository, epic: epic, state: "blocked_by_epic")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

    prerequisite.approve!(via: "operator")
    prerequisite.save!

    expect(job.reload).to be_queued
    expect(workflow.first_step.runs.last).to be_queued
  end
end
