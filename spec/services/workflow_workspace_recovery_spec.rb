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

  it "reconstructs the exact durable head and resumes a stranded grader collector" do
    step = workflow.steps.create!(kind: "grader_collect", position: 99, state: "running", started_at: 2.minutes.ago)
    run = step.runs.create!(
      job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
      state: "running", started_at: 2.minutes.ago
    )
    recovery = described_class.new(workflow: workflow, workspace: workspace, git: git)
    allow(recovery).to receive(:durable_candidates).and_return([ candidate ])

    expect {
      result = recovery.call
      expect(result).to have_attributes(status: "recovered", run: run)
    }.to have_enqueued_job(RunJob).with(run.id)

    expect(run.reload).to be_queued
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
end
