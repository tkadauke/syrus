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

  it "increments the version index for a new source" do
    described_class.call(job: job, workflow: workflow, run: run, base_sha: "base", head_sha: "head", files: files)
    other_run = Run.create!(job: job, step: job.workflows.first.steps.first, trigger_kind: "pr_comment", agent_provider: job.agent_provider, state: "succeeded")

    version = described_class.call(job: job, workflow: workflow, run: other_run, base_sha: "base", head_sha: "head", files: files)

    expect(version.version_index).to eq(2)
    expect(job.diff_review_versions.order(:version_index).pluck(:source_key)).to eq([
      "workflow:#{workflow.id}:run:#{run.id}",
      "workflow:#{workflow.id}:run:#{other_run.id}"
    ])
  end
end
