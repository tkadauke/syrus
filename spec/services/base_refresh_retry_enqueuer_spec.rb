require "rails_helper"

RSpec.describe BaseRefreshRetryEnqueuer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "failed", branch_name: nil) }
  let(:source) do
    Workflow.create!(job: job, trigger_kind: "initial", state: "failed", started_at: 10.minutes.ago,
      finished_at: 1.minute.ago, artifacts: { RebaseTarget::BASE_SHA_ARTIFACT => "old-base" })
  end
  let(:step) { Step.create!(workflow: source, kind: "implement", position: 0, state: "succeeded") }
  let(:run) do
    step.runs.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude",
      state: "succeeded", head_sha: "checkpoint-sha", base_sha: "old-base")
  end

  before do
    RunCheckpoint.create!(run: run, workflow: source, step: step, job: job, repository: repository, user: user,
      step_kind: "implement", commit_sha: "checkpoint-sha", base_sha: "old-base",
      remote_ref: RunCheckpoint.remote_ref_for(run), status: "published", published_at: Time.current)
    reader = instance_double(RepositoryContent::Reader, read_if_present: nil)
    allow(reader).to receive(:resolve) do |ref, **|
      sha = ref == RunCheckpoint.remote_ref_for(run) ? "checkpoint-sha" : "new-base"
      RepositoryContent::Revision.new(id: sha, ref: ref, observed_at: Time.current)
    end
    allow(RepositoryContent).to receive(:for).and_return(reader)
  end

  it "moves the failed Job to queued and starts a new branchless workflow Run" do
    result = described_class.call(job: job, source_workflow: source, reason: "base repaired")

    expect(result).to be_success
    expect(result.launch_result).to be_started
    expect(result.workflow.first_step.runs.count).to eq(1)
    expect(job.reload).to be_queued
    expect(result.workflow.artifacts).to include(
      RebaseTarget::BRANCH_ARTIFACT => "syrus/issue-#{job.issue_number}-#{job.id}",
      RebaseTarget::BASE_SHA_ARTIFACT => "new-base",
      "checkpoint_source_workflow_id" => source.id,
      "checkpoint_source_run_id" => run.id,
      "base_refresh_old_base_sha" => "old-base"
    )
    expect(source.reload).to be_failed
  end

  it "fails safely without a checkpoint" do
    run.run_checkpoint.destroy!
    result = described_class.call(job: job, source_workflow: source, reason: "base repaired")
    expect(result.error).to include("No published mutation checkpoint")
    expect(job.reload).to be_failed
  end

  it "returns a failure when dispatch does not start" do
    launch = WorkUnits::Launcher::Result.new(workflow: nil, run: nil, intent: nil, work_unit: nil,
      status: "not_started", reason: "job not ready", gate_result: nil)
    allow(WorkUnits::Launcher).to receive(:start!).and_return(launch)
    result = described_class.call(job: job, source_workflow: source, reason: "base repaired")
    expect(result).not_to be_success
    expect(result.error).to include("did not start: job not ready")
  end

  it "preserves the failed state when active mutation work owns the lock" do
    allow(WorkUnits::Launcher).to receive(:instantiate).and_raise(
      WorkUnits::Launcher::LockConflict.new(lock_key: "job:#{job.id}", work_unit: nil)
    )
    result = described_class.call(job: job, source_workflow: source, reason: "base repaired")
    expect(result.error).to include("Active mutation work")
    expect(job.reload).to be_failed
  end

  it "pins the effective stacked parent ref" do
    allow(job).to receive(:effective_base_branch).and_return("syrus/parent")
    result = described_class.call(job: job, source_workflow: source, reason: "parent advanced")
    expect(result).to be_success
    expect(result.workflow.artifacts).to include(RebaseTarget::BASE_BRANCH_ARTIFACT => "syrus/parent")
  end

  it "recovers a quiescent blocked source and clears stale attention only after replacement ownership exists" do
    source.update!(state: "blocked")
    add_recoverable_blocked_failure
    job.update!(needs_attention: true, needs_attention_reason: "agent_cannot_proceed", needs_attention_since: 1.hour.ago)

    result = described_class.call(job: job, source_workflow: source, reason: "restore durable implementation")

    expect(result).to be_success
    expect(result.workflow.work_unit).to be_present
    expect(source.reload).to be_blocked
    expect(job.reload.needs_attention_reason).to be_nil
  end

  it "converges repeated requests on the checkpoint reservation" do
    source.update!(state: "blocked")
    add_recoverable_blocked_failure

    first = described_class.call(job: job, source_workflow: source, reason: "restore durable implementation")
    second = described_class.call(job: job.reload, source_workflow: source.reload, reason: "restore durable implementation")

    expect(second).to be_success
    expect(second.workflow).to eq(first.workflow)
    expect(job.workflows.where(trigger_kind: "base_refresh_retry").count).to eq(1)
  end

  it "rejects a blocked source whose checkpoint provenance belongs to another Job" do
    source.update!(state: "blocked")
    add_recoverable_blocked_failure
    other = Factories.job_record(user: user, repository: repository, state: "failed")
    run.run_checkpoint.update_columns(job_id: other.id)

    result = described_class.call(job: job, source_workflow: source, reason: "restore durable implementation")

    expect(result.error).to include("checkpoint provenance")
    expect(job.reload).to be_failed
  end

  it "rejects a blocked source with an active Run" do
    source.update!(state: "blocked")
    add_recoverable_blocked_failure
    step.runs.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude", state: "queued")

    result = described_class.call(job: job, source_workflow: source, reason: "restore durable implementation")

    expect(result.error).to include("still has queued or running Runs")
  end

  it "rejects a blocked source with active ownership before reserving its checkpoint" do
    source.update!(state: "blocked")
    add_recoverable_blocked_failure
    allow(WorkUnits::Ownership).to receive(:active_for_job?).with(job).and_return(true)

    result = described_class.call(job: job, source_workflow: source, reason: "restore durable implementation")

    expect(result.error).to include("active WorkUnit ownership or retained mutation locks")
    expect(source.artifact("base_refresh_retry_workflow_id")).to be_nil
  end

  it "rejects a checkpoint whose durable ref no longer reaches the recorded commit" do
    source.update!(state: "blocked")
    add_recoverable_blocked_failure
    allow(RepositoryContent).to receive(:for).and_return(
      instance_double(RepositoryContent::Reader, resolve: RepositoryContent::Revision.new(
        id: "different-sha", ref: RunCheckpoint.remote_ref_for(run), observed_at: Time.current
      ))
    )

    result = described_class.call(job: job, source_workflow: source, reason: "restore durable implementation")

    expect(result.error).to include("does not resolve to its recorded commit SHA")
  end


  it "rejects an ambiguous blocked source without structured infrastructure failure evidence" do
    source.update!(state: "blocked")

    result = described_class.call(job: job, source_workflow: source, reason: "restore durable implementation")

    expect(result.error).to include("no structured recoverable infrastructure failure evidence")
  end

  def add_recoverable_blocked_failure
    grader = Step.create!(workflow: source, kind: "grader", position: 1, state: "failed")
    failed_run = grader.runs.create!(job: job, user: user, trigger_kind: "initial", state: "failed")
    RunFailureClassification.create!(run: failed_run, classification: "storage_unavailable",
      retryable: true, confidence: 1.0, reason: "structured test evidence", classified_at: Time.current)
  end
end
