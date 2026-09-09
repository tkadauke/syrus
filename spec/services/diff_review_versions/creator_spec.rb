require "rails_helper"

RSpec.describe DiffReviewVersions::Creator do
  let(:job) { Factories.job_with_run(run_attrs: { base_sha: "aabbccdd1234567", head_sha: "deadbeef12345678" }) }
  let(:workflow) { job.workflows.first }
  let(:run) { job.runs.first }
  let(:files) do
    [
      { path: "app/models/user.rb", status: "modified", additions: 4, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" }
    ]
  end

  it "creates the next immutable diff review version" do
    version = described_class.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      base_ref: "main",
      head_ref: "syrus/issue-42",
      files: files,
      truncated: false,
      label: "Initial implementation",
      reason: "initial"
    )

    expect(version).to have_attributes(
      version_index: 1,
      workflow_id: workflow.id,
      run_id: run.id,
      base_ref: "main",
      head_ref: "syrus/issue-42",
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      trigger_kind: "initial",
      label: "Initial implementation",
      reason: "initial",
      truncated: false
    )
    expect(version.files_snapshot).to contain_exactly(
      "path" => "app/models/user.rb",
      "status" => "modified",
      "additions" => 4,
      "deletions" => 1,
      "patch" => "@@ -1 +1 @@\n-old\n+new"
    )
  end

  it "is idempotent for the same job, SHA pair, and source" do
    first = described_class.call(job: job, workflow: workflow, run: run, base_sha: "base", head_sha: "head", files: files)
    second = described_class.call(job: job, workflow: workflow, run: run, base_sha: "base", head_sha: "head", files: [])

    expect(second).to eq(first)
    expect(job.diff_review_versions.count).to eq(1)
    expect(second.files_snapshot).to eq(first.files_snapshot)
  end

  it "reuses the existing version for the same immutable SHA pair from a new source" do
    described_class.call(job: job, workflow: workflow, run: run, base_sha: "base", head_sha: "head", files: files)
    other_run = Run.create!(job: job, step: job.workflows.first.steps.first, trigger_kind: "pr_comment", agent_provider: job.agent_provider, state: "succeeded")

    version = described_class.call(job: job, workflow: workflow, run: other_run, base_sha: "base", head_sha: "head", files: files)

    expect(version.version_index).to eq(1)
    expect(job.diff_review_versions.order(:version_index).pluck(:source_key)).to eq([
      "workflow:#{workflow.id}:run:#{run.id}"
    ])
  end

  it "labels chat feedback versions with a reviewable sequence number" do
    first_workflow = Workflow.create!(job: job, trigger_kind: "chat_feedback", agent_provider: job.agent_provider)
    first_step = Step.create!(workflow: first_workflow, kind: "respond", position: 0)
    first_run = Run.create!(job: job, step: first_step, trigger_kind: "chat_feedback", agent_provider: job.agent_provider)
    second_workflow = Workflow.create!(job: job, trigger_kind: "chat_feedback", agent_provider: job.agent_provider)
    second_step = Step.create!(workflow: second_workflow, kind: "respond", position: 0)
    second_run = Run.create!(job: job, step: second_step, trigger_kind: "chat_feedback", agent_provider: job.agent_provider)

    first = described_class.call(job: job, workflow: first_workflow, run: first_run, base_sha: "base-1", head_sha: "head-1", files: files)
    second = described_class.call(job: job, workflow: second_workflow, run: second_run, base_sha: "base-2", head_sha: "head-2", files: files)

    expect(first.label).to eq("Chat feedback #1")
    expect(second.label).to eq("Chat feedback #2")
  end

  it "uses user-facing default labels for lifecycle trigger kinds" do
    retry_workflow = Workflow.create!(job: job, trigger_kind: "retry", agent_provider: job.agent_provider)

    version = described_class.call(job: job, workflow: retry_workflow, base_sha: "base-retry", head_sha: "head-retry", files: files)

    expect(version.label).to eq("Retry")
    expect(version.reason).to be_nil
    expect(version.trigger_kind).to eq("retry")
  end
end
