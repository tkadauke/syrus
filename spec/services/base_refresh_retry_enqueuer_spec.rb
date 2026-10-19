require "rails_helper"

RSpec.describe BaseRefreshRetryEnqueuer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "failed", branch_name: nil) }
  let(:source) { Workflow.create!(job: job, trigger_kind: "initial", state: "failed", artifacts: { "rebase_base_sha" => "old-base" }) }
  let(:step) { Step.create!(workflow: source, kind: "implement", position: 1, state: "succeeded") }
  let(:run) do
    step.runs.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude",
                      state: "succeeded", head_sha: "checkpoint-sha", base_sha: "old-base")
  end

  before do
    RunCheckpoint.create!(
      run: run, workflow: source, step: step, job: job, repository: repository, user: user,
      step_kind: "implement", commit_sha: "checkpoint-sha", base_sha: "old-base",
      remote_ref: RunCheckpoint.remote_ref_for(run), status: "published", published_at: Time.current
    )
    revision = RepositoryContent::Revision.new(id: "new-base", ref: repository.default_branch, observed_at: Time.current)
    reader = instance_double(RepositoryContent::Reader, resolve: revision, read_if_present: nil)
    allow(RepositoryContent).to receive(:for).and_return(reader)
    allow(WorkUnits::Launcher).to receive(:start!)
  end

  it "creates a distinct branchless checkpoint workflow pinned to the current effective base" do
    snapshot = WorkflowSourceSnapshots.record!(
      workflow: source, creator_step: step, source_sha: "checkpoint-sha",
      source_ref: "refs/syrus/source-snapshots/source", tree_sha: "tree-sha"
    )
    result = described_class.call(job: job, source_workflow: source, reason: "refresh after base repair")

    expect(result).to be_success
    expect(result.workflow).not_to eq(source)
    expect(result.workflow.trigger_kind).to eq("base_refresh_retry")
    expect(result.workflow.artifacts).to include(
      "checkpoint_sha" => "checkpoint-sha",
      "checkpoint_source_workflow_id" => source.id,
      "checkpoint_source_run_id" => run.id,
      "rebase_base_sha" => "new-base",
      "base_refresh_old_base_sha" => "old-base",
      "base_refresh_source_snapshot_id" => snapshot.id,
      "base_refresh_source_snapshot_sha" => "checkpoint-sha",
      "base_refresh_reason" => "refresh after base repair"
    )
    expect(result.workflow.steps.pluck(:kind)).to include(
      "base_refresh_rebase", "agent_rebase", "publish_source_snapshot", "prepare", "summarize", "test_plan", "pr_open"
    )
    expect(result.workflow.steps.pluck(:kind)).not_to include("implement")
  end

  it "resolves a stacked Job's current parent branch instead of its default branch" do
    allow(job).to receive(:effective_base_branch).and_return("syrus/parent")

    described_class.call(job: job, source_workflow: source, reason: "refresh stack")

    expect(RepositoryContent).to have_received(:for).with(repository, user: user).at_least(:once)
  end

  it "fails safely when the selected workflow has no published mutation checkpoint" do
    run.run_checkpoint.destroy!

    result = described_class.call(job: job, source_workflow: source, reason: "refresh")

    expect(result).not_to be_success
    expect(result.error).to include("No published mutation checkpoint")
    expect(WorkUnits::Launcher).not_to have_received(:start!)
  end

  it "reports active mutation lock conflicts without starting another workflow" do
    allow(WorkUnits::Launcher).to receive(:instantiate).and_raise(
      WorkUnits::Launcher::LockConflict.new(lock_key: "job:#{job.id}", work_unit: nil)
    )

    result = described_class.call(job: job, source_workflow: source, reason: "refresh")

    expect(result.error).to include("Active mutation work")
  end

  it "records terminal provenance outcomes without changing the source workflow" do
    result = described_class.call(job: job, source_workflow: source, reason: "refresh")

    Workflows::BaseRefreshRetry.after_fail(result.workflow)

    expect(result.workflow.reload.artifact("base_refresh_outcome")).to include("status" => "failed")
    expect(source.reload).to be_failed
  end
end
