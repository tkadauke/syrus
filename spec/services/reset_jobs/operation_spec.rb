require "rails_helper"

RSpec.describe ResetJobs::Operation, :hierarchical_locks do
  let(:user) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user:) }
  let(:action) { instance_double(ChatPendingAction, id: 91) }
  let(:client) { instance_double(GithubClient, close_pull_request: true, delete_branch: true, delete_ref: true) }

  before do
    allow(GithubClient).to receive(:for).and_return(client)
    allow(WorkflowWorkspace).to receive(:cleanup_for).and_return(true)
  end

  it "returns a failed Job to normal queued admission with a fresh initial Workflow" do
    job = Factories.job_record(user:, repository:, state: "failed")

    described_class.new(job:, user:, reason: "Start over", pending_action: action).call

    expect(job.reload).to be_queued
    expect(job.workflows.where(trigger_kind: "initial")).to exist
  end

  it "cancels active runtime history, every active WorkUnit, and releases its locks" do
    job = Factories.job_with_run(user:, repository:, state: "running",
      workflow_attrs: { state: "running" }, step_attrs: { state: "running" }, run_attrs: { state: "running" })
    workflow = job.workflows.sole
    historical_run = job.runs.sole
    runtime_unit = attach_work_unit(workflow, state: "running")
    intent = WorkIntent.create!(kind: "manual", state: "requested", repository:, scope_type: "job",
      scope_id: job.id, actor: user, source_type: "spec")
    other_unit = WorkUnit.create!(work_intent: intent, kind: "manual", state: "running", repository:,
      scope_type: "job", scope_id: job.id)
    other_unit.work_unit_members.create!(job:, role: "primary")
    lock = other_unit.work_unit_locks.create!(lock_key: "reset-spec:#{job.id}")

    described_class.new(job:, user:, reason: "Discard stale work", pending_action: action).call

    expect([ runtime_unit.reload, other_unit.reload ]).to all(be_cancelled)
    expect(lock.reload).not_to be_active
    expect(workflow.reload).to be_cancelled
    expect(workflow.artifacts).to include("reset_reason" => "Discard stale work", "reset_actor_id" => user.id)
    expect(historical_run.reload.artifacts).to include("reset_reason" => "Discard stale work")
    expect(job.workflows.where(trigger_kind: "initial").count).to eq(2)
  end

  it "lists and cancels active compatibility Workflows and Runs without WorkUnit ownership" do
    job = Factories.job_with_run(user:, repository:, state: "running",
      workflow_attrs: { state: "running" }, step_attrs: { state: "running" }, run_attrs: { state: "running" })
    workflow = job.workflows.sole
    run = job.runs.sole

    expect(WorkUnits::Ownership.active_units_for_job(job)).to be_empty
    expect(described_class.destruction_summary(job)[:active_workflows]).to eq([ workflow.id ])

    described_class.new(job:, user:, reason: "Discard compatibility work", pending_action: action).call

    expect(workflow.reload).to be_cancelled
    expect(run.reload).to be_cancelled
    expect(workflow.artifacts).to include("reset_reason" => "Discard compatibility work")
    expect(run.artifacts).to include("reset_reason" => "Discard compatibility work")
  end

  it "lists and cancels an indirectly owned child Workflow" do
    epic = Factories.epic(user:, repository:)
    anchor = Factories.job_with_run(user:, repository:, epic:, state: "running", issue_number: 50,
      workflow_attrs: { state: "running", trigger_kind: "merge_train_validation" },
      step_attrs: { state: "running" }, run_attrs: { state: "running", trigger_kind: "merge_train_validation" })
    member = Factories.job_record(user:, repository:, epic:, state: "running", issue_number: 51)
    workflow = anchor.workflows.sole
    run = anchor.runs.sole
    unit = attach_work_unit(workflow, state: "running", kind: "merge_train_validation", member_jobs: [ anchor, member ])

    expect(workflow.job).to eq(anchor)
    expect(WorkDefinitions.for(unit.kind)).to be_child
    expect(described_class.destruction_summary(member)[:active_workflows]).to eq([ workflow.id ])

    described_class.new(job: member, user:, reason: "Reset member", pending_action: action).call

    expect(workflow.reload).to be_cancelled
    expect(unit.reload).to be_cancelled
    expect(run.reload).to be_cancelled
    expect(run.artifacts).to include("reset_reason" => "Reset member")
    expect(member.reload).to be_blocked_by_epic
  end

  it "removes an implemented Job's PR, branch, checkpoints, and workspace while retaining history" do
    job = Factories.job_with_run(user:, repository:, state: "implemented", branch_name: "syrus/old", pr_number: 12)
    workflow = job.workflows.sole
    run = job.runs.sole
    checkpoint = RunCheckpoint.create!(run:, workflow:, step: run.step, job:, repository:, user:,
      step_kind: run.step.kind, commit_sha: "a" * 40, remote_ref: RunCheckpoint.remote_ref_for(run), status: "published")

    described_class.new(job:, user:, reason: "Start clean", pending_action: action).call

    expect(client).to have_received(:close_pull_request).with(repository.slug, 12)
    expect(client).to have_received(:delete_branch).with(repository.slug, "syrus/old")
    expect(client).to have_received(:delete_ref).with(repository.slug, checkpoint.remote_ref)
    expect(WorkflowWorkspace).to have_received(:cleanup_for).with(workflow, force_local: true, actor: "reset_job", reason: "Start clean")
    expect(job.reload).to have_attributes(state: "queued", pr_number: nil, branch_name: nil)
    expect(job.workflows).to include(workflow)
    expect(RunCheckpoint.where(job:)).to be_empty
  end

  it "returns a Job with an unsatisfied dependency to blocked without starting work" do
    prerequisite = Factories.job_record(user:, repository:, state: "failed", issue_number: 42)
    job = Factories.job_record(user:, repository:, state: "failed", issue_number: 43)
    JobDependency.create!(job:, depends_on_job: prerequisite, source: "manual")

    described_class.new(job:, user:, reason: "Start over", pending_action: action).call

    expect(job.reload).to be_blocked_by_epic
    expect(job.workflows).to be_empty
  end

  it "refuses merged Jobs, live stacked parents, and active merge-train members" do
    merged = Factories.job_record(user:, repository:, state: "closed", closure_reason: "pr_merged")
    parent = Factories.job_record(user:, repository:, state: "failed", issue_number: 44)
    Factories.job_record(user:, repository:, state: "running", issue_number: 45,
      parent_job_id: parent.id, branch_name: "syrus/child")
    train_job = Factories.job_record(user:, repository:, state: "failed", issue_number: 46)
    train = MergeTrain.create!(repository:, base_branch: repository.default_branch, priority: "medium", state: "grading")
    MergeTrainMember.create!(merge_train: train, job: train_job, position: 0)

    expect(described_class.preflight(merged)).to include("create a new Job")
    expect(described_class.preflight(parent)).to include("Live stacked children", parent.stack_children.sole.slug)
    expect(described_class.preflight(train_job)).to include("cancel the merge train")
  end

  it "localizes refusal messages" do
    merged = Factories.job_record(user:, repository:, state: "closed", closure_reason: "pr_merged", issue_number: 60)

    %i[de la].each do |locale|
      I18n.with_locale(locale) do
        message = described_class.preflight(merged)
        expect(message).to include(merged.slug)
        expect(message).not_to eq(I18n.t("reset_jobs.refusals.merged", slug: merged.slug, locale: :en))
      end
    end
  end
end
