require "rails_helper"

RSpec.describe MergeTrainDispatcher do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }
  let(:epic) { Factories.epic(user: user, repository: repository) }

  def approved_child(issue_number)
    Factories.job_record(
      user: user, repository: repository, epic: epic,
      issue_number: issue_number, state: "approved",
      pr_number: 500 + issue_number, branch_name: "syrus/issue-#{issue_number}"
    )
  end

  before do
    AppSetting.current.update!(merge_train_enabled: true)
    epic.update_columns(state: "in_progress")
    epic.reload
    allow(StepDispatcher).to receive(:start_workflow)
  end

  it "creates a train, locks members into :landing, and starts the workflow" do
    a = approved_child(1)
    b = approved_child(2)

    expect(described_class.blocker_reason(epic)).to be_nil
    workflow = described_class.try_dispatch!(epic)

    expect(workflow).to be_present
    expect(workflow.trigger_kind).to eq("merge_train")
    train = MergeTrain.last
    expect(train.epic).to eq(epic)
    expect(train.base_branch).to eq(repository.default_branch)
    expect(train.members.count).to eq(2)
    expect(workflow.artifact("merge_train_id")).to eq(train.id)
    expect(a.reload.state).to eq("landing")
    expect(b.reload.state).to eq("landing")
    expect(StepDispatcher).to have_received(:start_workflow).with(workflow)
  end

  it "starts a linear Epic stack without creating a standalone reconciliation Job" do
    allow(StepDispatcher).to receive(:start_workflow).and_call_original
    root = approved_child(1)
    leaf = approved_child(2)
    leaf.update!(parent_job: root)
    workflow = nil

    expect {
      workflow = described_class.try_dispatch!(epic)
    }.not_to change(Job, :count)

    train = MergeTrain.last
    expect(train.member_jobs).to eq([ root, leaf ])
    expect(epic.jobs.where("issue_title LIKE ?", "Reconciliation:%")).to be_empty
    expect(workflow.steps.order(:position).pluck(:kind)).to include("merge_train_reconcile")
    expect(workflow.first_step.runs.count).to eq(1)
    expect(workflow.artifact("start_blocked_reason")).to be_nil
  end

  it "starts a nonlinear fan-in train with every leaf and no reconciliation fan-in Job" do
    allow(StepDispatcher).to receive(:start_workflow).and_call_original
    root = approved_child(1)
    leaf_a = approved_child(2)
    leaf_b = approved_child(3)
    leaf_a.update!(parent_job: root)
    leaf_b.update!(parent_job: root)
    workflow = nil

    expect {
      workflow = described_class.try_dispatch!(epic)
    }.not_to change(Job, :count)

    train = MergeTrain.last
    expect(train.member_jobs).to eq([ root, leaf_a, leaf_b ])
    expect(JobDependency.where(job_id: epic.jobs.select(:id))).to be_empty
    expect(workflow.first_step.runs.count).to eq(1)
    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ merge_train_assemble merge_train_build merge_train_reconcile prepare grader_fanout grader_collect merge_train_land ]
    )
  end

  it "does nothing when the merge-train flag is off" do
    AppSetting.current.update!(merge_train_enabled: false)
    approved_child(1)

    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.count).to eq(0)
  end

  it "does nothing when the Epic has not released its children for execution" do
    epic.update_columns(state: "backlog")
    epic.reload
    approved_child(1)

    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(described_class.blocker_reason(epic)).to eq("waiting for Epic to release")
    expect(MergeTrain.count).to eq(0)
    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "does nothing when the Epic is not ready (a child is unapproved)" do
    approved_child(1)
    Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2,
                         state: "implemented", pr_number: 502, branch_name: "syrus/issue-2")

    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.count).to eq(0)
  end

  it "does nothing when the repository already has a landing in progress" do
    approved_child(1)
    Factories.job_record(user: user, repository: repository, issue_number: 99, state: "landing", pr_number: 999)

    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.count).to eq(0)
  end

  it "does nothing when another active work unit owns the repository landing lock" do
    approved_child(1)
    landing_owner = Factories.job_record(user: user, repository: repository, issue_number: 99, state: "approved", pr_number: 999)
    workflow = WorkUnits::Launcher.instantiate(kind: "auto_merge", job: landing_owner)
    workflow.work_unit.update!(state: "running")

    expect(described_class.blocker_reason(epic)).to eq("#{landing_owner.slug} is already landing for #{repository.slug}")
    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.count).to eq(0)
  end

  it "rechecks WorkUnit landing locks inside the dispatch transaction" do
    approved_child(1)
    landing_owner = Factories.job_record(user: user, repository: repository, issue_number: 99, state: "implemented", pr_number: 999)
    workflow = WorkUnits::Launcher.instantiate(kind: "auto_merge", job: landing_owner)
    workflow.work_unit.update!(state: "running")
    dispatcher = described_class.new(epic)
    allow(dispatcher).to receive(:blocker_reason).and_return(nil)

    expect(dispatcher.try_dispatch!).to be_nil
    expect(MergeTrain.count).to eq(0)
    expect(epic.jobs.reload.pluck(:state)).to all(eq("approved"))
  end

  it "does not dispatch a second train when the Epic already has an active train" do
    approved_child(1)
    active_train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master", state: "grading")

    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.all).to contain_exactly(active_train)
    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "does not dispatch a second train when the Epic already has an active merge-train workflow" do
    child = approved_child(1)
    Workflow.create!(job: child, trigger_kind: "merge_train", state: "running")

    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.count).to eq(0)
    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "ignores legacy merge-train workflows as active train blockers when WorkUnit landing owns the path" do
    Feature.find_or_create_by!(slug: "work_units_landing") do |feature|
      feature.category = "Operations"
      feature.name = "Work units landing"
    end.update!(enabled: true)
    child = approved_child(1)
    Workflow.create!(job: child, trigger_kind: "merge_train", state: "running")

    expect(described_class.blocker_reason(epic)).to be_nil
  end

  it "does not dispatch when an active merge-train work unit owns the Epic" do
    first = approved_child(1)
    second = approved_child(2)
    other_epic_job = Factories.job_record(user: user, repository: repository, issue_number: 99, state: "queued")
    workflow = Workflow.create!(job: other_epic_job, trigger_kind: "merge_train", state: "running")
    intent = WorkIntent.create!(
      kind: "merge_train",
      state: "requested",
      repository: repository,
      scope_type: "epic",
      scope_id: epic.id,
      actor: user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: "merge_train",
      state: "running",
      repository: repository,
      scope_type: "epic",
      scope_id: epic.id,
      workflow: workflow
    )
    [ first, second ].each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end

    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.count).to eq(0)
    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "does not dispatch the real train while speculative train validation is active" do
    child = approved_child(1)
    Workflow.create!(job: child, trigger_kind: "merge_train_validation", state: "running")

    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.count).to eq(0)
    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "does not dispatch while a rebase workflow is active for a train member" do
    child = approved_child(1)
    workflow = Workflow.create!(job: child, trigger_kind: "stack_rebase", state: "running")
    Step.create!(workflow: workflow, kind: "stack_agent_rebase", position: 0)

    expect(described_class.blocker_reason(epic)).to eq("active rebase workflow #{workflow.slug} must finish before the merge train starts")
    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.count).to eq(0)
    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "does not dispatch while a rebase WorkUnit owns a train member before a workflow is linked" do
    child = approved_child(1)
    intent = WorkIntent.create!(
      kind: "stack_rebase",
      state: "requested",
      repository: repository,
      scope_type: "job",
      scope_id: child.id,
      actor: user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: "stack_rebase",
      state: "running",
      repository: repository,
      scope_type: "job",
      scope_id: child.id
    )
    unit.work_unit_members.create!(job: child, role: "primary")

    expect(described_class.blocker_reason(epic)).to eq("active rebase workflow must finish before the merge train starts")
    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.count).to eq(0)
    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "does not create a train when an approved Epic stack has unresolved external blockers" do
    blocker = Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 9,
      state: "implemented",
      pr_number: 509,
      branch_name: "syrus/issue-9"
    )
    child = approved_child(1)
    JobDependency.create!(job: child, depends_on_job: blocker, source: "manual")

    expect(described_class.blocker_reason(epic)).to eq("stack dependencies not ready: #{blocker.slug}")
    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.count).to eq(0)
    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "does not re-dispatch during the cooldown after a failed train" do
    approved_child(1)
    MergeTrain.create!(epic: epic, repository: repository, base_branch: "master",
                       state: "failed", finished_at: 5.minutes.ago)

    expect(described_class.try_dispatch!(epic)).to be_nil
    expect(MergeTrain.where(state: "building").count).to eq(0)
  end

  it "allows explicit rebuilds to bypass the failed-train cooldown" do
    approved_child(1)
    MergeTrain.create!(epic: epic, repository: repository, base_branch: "master",
                       state: "failed", failure_reason: "merge_train failed", finished_at: 5.minutes.ago)

    expect(described_class.try_dispatch!(epic, bypass_cooldown: true)).to be_present
  end

  it "re-dispatches immediately after a stale-base train failure" do
    approved_child(1)
    MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "master",
      state: "failed",
      failure_reason: "merge_train: base moved from oldbase to newbase; rebuild required",
      finished_at: 5.minutes.ago
    )

    expect(described_class.try_dispatch!(epic)).to be_present
  end

  it "re-dispatches immediately after an old train missing base tracking fails" do
    approved_child(1)
    MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "master",
      state: "failed",
      failure_reason: "merge_train: missing built base SHA; rebuild required",
      finished_at: 5.minutes.ago
    )

    expect(described_class.try_dispatch!(epic)).to be_present
  end

  it "re-dispatches immediately after a transient landing-start blocker failure" do
    approved_child(1)
    MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "master",
      state: "failed",
      failure_reason: "landing start blocked: dependency failed",
      finished_at: 5.minutes.ago
    )

    expect(described_class.try_dispatch!(epic)).to be_present
  end

  it "re-dispatches once the cooldown has elapsed" do
    approved_child(1)
    MergeTrain.create!(epic: epic, repository: repository, base_branch: "master",
                       state: "failed", finished_at: (described_class::RETRY_COOLDOWN + 1.minute).ago)

    expect(described_class.try_dispatch!(epic)).to be_present
  end
end
