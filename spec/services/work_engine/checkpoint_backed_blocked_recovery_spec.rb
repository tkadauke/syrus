require "rails_helper"

RSpec.describe "checkpoint-backed blocked Workflow recovery" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "failed", branch_name: nil) }
  let(:workflow) do
    Workflow.create!(job: job, trigger_kind: "initial", state: "blocked",
      started_at: 10.minutes.ago, finished_at: 5.minutes.ago)
  end
  let(:step) { Step.create!(workflow: workflow, kind: "implement", position: 0, state: "succeeded") }
  let(:run) do
    step.runs.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude",
      state: "succeeded", head_sha: "implementation-sha", base_sha: "old-base")
  end

  before do
    RunCheckpoint.create!(run: run, workflow: workflow, step: step, job: job, repository: repository, user: user,
      step_kind: "implement", commit_sha: "implementation-sha", base_sha: "old-base",
      remote_ref: RunCheckpoint.remote_ref_for(run), status: "published", published_at: Time.current)
    grader = Step.create!(workflow: workflow, kind: "grader", position: 1, state: "failed")
    failed_run = grader.runs.create!(job: job, user: user, trigger_kind: "initial", state: "failed")
    RunFailureClassification.create!(run: failed_run, classification: "worker_died",
      retryable: true, confidence: 1.0, reason: "worker disappeared", classified_at: Time.current)
    reader = instance_double(RepositoryContent::Reader, read_if_present: nil)
    allow(reader).to receive(:resolve) do |ref, **|
      sha = ref == RunCheckpoint.remote_ref_for(run) ? "implementation-sha" : "current-base"
      RepositoryContent::Revision.new(id: sha, ref: ref, observed_at: Time.current)
    end
    allow(RepositoryContent).to receive(:for).and_return(reader)
  end

  it "classifies and automatically restores the checkpoint through normal admission" do
    result = WorkEngine::Reconciler.call(source: "spec", job_id: job.id, execute_repairs: true)

    issue = result.issues.find { |candidate| candidate.kind == "checkpoint_backed_blocked_workflow" }
    execution = result.repair_executions.find { |candidate| candidate.action == "refresh_base_from_blocked_checkpoint" }
    replacement = job.workflows.find_by(trigger_kind: "base_refresh_retry")

    expect(issue).to have_attributes(safe_to_auto_repair: true)
    expect(execution).to have_attributes(status: "applied")
    expect(replacement).to be_present
    expect(replacement.artifacts).to include("checkpoint_sha" => "implementation-sha")
    expect(workflow.reload).to be_blocked
  end

  it "converges across repeated reconciler passes without another replacement" do
    2.times { WorkEngine::Reconciler.call(source: "spec", job_id: job.id, execute_repairs: true) }

    expect(job.workflows.where(trigger_kind: "base_refresh_retry").count).to eq(1)
    expect(WorkUnit.where(workflow_id: job.workflows.where(trigger_kind: "base_refresh_retry")).count).to eq(1)
  end
end
