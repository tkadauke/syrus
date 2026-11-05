require "rails_helper"

RSpec.describe WorkflowWorkspaceRecovery do
  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:workspace) { instance_double(WorkflowWorkspace, path: Pathname("/tmp/recovered-workspace")) }
  let(:git) { instance_double(GitRunner) }
  let(:candidate) do
    described_class::Candidate.new(
      ref: "refs/syrus/checkpoints/runs/42",
      sha: "a" * 40,
      published_at: Time.current,
      id: 42,
      source: "run_checkpoint"
    )
  end

  before do
    workflow.update_columns(state: "running", started_at: 5.minutes.ago)
    allow(workspace).to receive(:reconstruct_from!).with(candidate.ref)
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: workspace.path.to_s).and_return("#{candidate.sha}\n")
    allow(WorkflowWorkspaceLifecycle).to receive(:record_identity!)
  end

  it "reconstructs the exact durable head and resumes stranded graders before their collector" do
    grader_runs = 2.times.map do |index|
      step = workflow.steps.create!(
        kind: "grader", position: 97 + index, state: index.zero? ? "running" : "queued",
        started_at: index.zero? ? 2.minutes.ago : nil
      )
      step.runs.create!(
        job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
        state: index.zero? ? "running" : "queued", started_at: index.zero? ? 2.minutes.ago : nil
      )
    end
    step = workflow.steps.create!(kind: "grader_collect", position: 99, state: "running", started_at: 2.minutes.ago)
    collector = step.runs.create!(
      job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
      state: "running", started_at: 2.minutes.ago
    )
    recovery = described_class.new(workflow: workflow, workspace: workspace, git: git)
    allow(recovery).to receive(:durable_candidates).and_return([ candidate ])

    expect {
      result = recovery.call
      expect(result).to have_attributes(status: "recovered", run: collector)
    }.to have_enqueued_job(RunJob).exactly(3).times

    enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    expect(enqueued_jobs.last(3).map { |entry| entry.fetch(:args).first }).to eq(
      grader_runs.map(&:id) + [ collector.id ]
    )
    expect(grader_runs.map { |run| run.reload.state }).to eq(%w[queued queued])
    expect(collector.reload).to be_queued
    expect(step.reload).to be_queued
    expect(WorkflowWorkspaceLifecycle).to have_received(:record_identity!).with(
      workflow, hostname: SyrusVersion.hostname, storage_key: WorkerStorageIdentity.queue_key,
      actor: "workspace_recovery"
    )
  end

  it "refuses to replay an already-running mutable step" do
    step = workflow.steps.create!(kind: "implement", position: 99, state: "running", started_at: 2.minutes.ago)
    run = step.runs.create!(
      job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
      state: "running", started_at: 2.minutes.ago
    )
    recovery = described_class.new(workflow: workflow, workspace: workspace, git: git)
    allow(recovery).to receive(:durable_candidates).and_return([ candidate ])

    expect(recovery.call).to have_attributes(status: "retry_required", run: run)
    expect(run.reload).to be_running
  end

  it "requires a fresh retry when no durable implementation state exists" do
    recovery = described_class.new(workflow: workflow, workspace: workspace, git: git)
    allow(recovery).to receive(:durable_candidates).and_return([])

    result = recovery.call

    expect(result).to have_attributes(status: "retry_required")
    expect(result.message).to include("no durable source snapshot")
    expect(workspace).not_to have_received(:reconstruct_from!)
  end

  it "rejects a valid snapshot that predates the latest successful mutation" do
    implementation_sha = "b" * 40
    source_sha = "c" * 40
    implement_step = workflow.steps.create!(kind: "implement", position: 90, state: "succeeded", finished_at: 2.minutes.ago)
    implement_step.runs.create!(
      job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
      state: "succeeded", head_sha: implementation_sha, finished_at: 2.minutes.ago
    )
    snapshot = WorkflowSourceSnapshot.create!(
      workflow: workflow, creator_step: implement_step, source_sha: source_sha,
      source_ref: "refs/syrus/source-snapshots/stale", tree_sha: "d" * 40,
      published_at: 1.minute.ago
    )
    recovery = described_class.new(workflow: workflow, workspace: workspace, git: git)
    allow(WorkflowSourceSnapshots).to receive(:current_for).with(workflow).and_return(snapshot)
    allow(recovery).to receive(:remote_sha).with(snapshot.source_ref).and_return(source_sha)
    allow(recovery).to receive(:remote_sha).with("refs/heads/#{job.branch_name}").and_return(nil)

    expect(recovery.durable_candidates).to be_empty
  end

  it "accepts a published checkpoint at the latest successful mutation head" do
    implementation_sha = "e" * 40
    implement_step = workflow.steps.create!(kind: "implement", position: 90, state: "succeeded", finished_at: 2.minutes.ago)
    implement_run = implement_step.runs.create!(
      job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
      state: "succeeded", head_sha: implementation_sha, finished_at: 2.minutes.ago
    )
    checkpoint = RunCheckpoint.create!(
      run: implement_run, workflow: workflow, step: implement_step, job: job,
      repository: job.repository, user: job.user, step_kind: "implement",
      commit_sha: implementation_sha, remote_ref: RunCheckpoint.remote_ref_for(implement_run),
      status: "published", published_at: 1.minute.ago
    )
    recovery = described_class.new(workflow: workflow, workspace: workspace, git: git)
    allow(WorkflowSourceSnapshots).to receive(:current_for).with(workflow).and_return(nil)
    allow(recovery).to receive(:remote_sha).with(checkpoint.remote_ref).and_return(implementation_sha)
    allow(recovery).to receive(:remote_sha).with("refs/heads/#{job.branch_name}").and_return(nil)

    expect(recovery.durable_candidates).to contain_exactly(
      have_attributes(source: "run_checkpoint", sha: implementation_sha)
    )
  end
end
