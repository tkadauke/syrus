require "rails_helper"

RSpec.describe DiffReviewVersion do
  let(:job) { Factories.job_with_run }
  let(:workflow) { job.workflows.first }
  let(:run) { job.runs.first }

  it "requires immutable SHA identity and a per-job version index" do
    version = described_class.create!(
      job: job,
      workflow: workflow,
      run: run,
      version_index: 1,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      source_key: "workflow:#{workflow.id}:run:#{run.id}",
      files_snapshot: [
        { "path" => "app/models/user.rb", "status" => "modified", "additions" => 4, "deletions" => 1, "patch" => "@@ -1 +1 @@\n-old\n+new" }
      ],
      metadata: { "source" => "spec" }
    )

    expect(version).to be_persisted
    expect(version.files_snapshot.first).to include("path" => "app/models/user.rb", "patch" => "@@ -1 +1 @@\n-old\n+new")
  end

  it "enforces idempotency by job, base SHA, head SHA, and source key" do
    attrs = {
      job: job,
      version_index: 1,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      source_key: "workflow:#{workflow.id}:run:#{run.id}",
      files_snapshot: [],
      metadata: {}
    }
    described_class.create!(attrs)

    duplicate = described_class.new(attrs.merge(version_index: 2))

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:source_key]).to include("has already been taken")
  end

  it "rejects workflow and run records from another job" do
    other_job = Factories.job_with_run(repository: job.repository, user: job.user, issue_number: 43)
    version = described_class.new(
      job: job,
      workflow: other_job.workflows.first,
      run: other_job.runs.first,
      version_index: 1,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      source_key: "workflow:#{other_job.workflows.first.id}:run:#{other_job.runs.first.id}",
      files_snapshot: [],
      metadata: {}
    )

    expect(version).not_to be_valid
    expect(version.errors[:workflow]).to include("must belong to the same job")
    expect(version.errors[:run]).to include("must belong to the same job")
  end
end
