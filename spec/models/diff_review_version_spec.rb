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

  it "does not default to an All changes version whose head SHA is actually the default branch name" do
    run_version = described_class.create!(
      job: job,
      workflow: workflow,
      run: run,
      version_index: 1,
      base_sha: "branch-base",
      head_sha: "implemented-head",
      source_key: "workflow:#{workflow.id}:run:#{run.id}",
      reason: "initial",
      files_snapshot: [],
      metadata: {}
    )
    described_class.create!(
      job: job,
      version_index: 2,
      base_sha: "old-main-base",
      head_sha: job.repository.default_branch,
      source_key: "source_diff",
      label: "All changes",
      reason: "source_diff",
      files_snapshot: [],
      metadata: { "range_kind" => "all_changes" }
    )

    expect(described_class.default_for_review(job)).to eq(run_version)
  end

  describe ".best_match_for" do
    it "prefers an exact run_id match" do
      version = described_class.create!(
        job: job, workflow: workflow, run: run, version_index: 1,
        base_sha: "aaa", head_sha: "bbb", source_key: "workflow:#{workflow.id}:run:#{run.id}",
        files_snapshot: [], metadata: {}
      )

      expect(described_class.best_match_for(job_id: job.id, run_id: run.id, workflow_id: workflow.id)).to eq(version)
    end

    it "falls back to the most recent version for the workflow when no run matches" do
      older = described_class.create!(
        job: job, workflow: workflow, version_index: 1,
        base_sha: "aaa", head_sha: "bbb", source_key: "wf-older",
        files_snapshot: [], metadata: {}
      )
      newer = described_class.create!(
        job: job, workflow: workflow, version_index: 2,
        base_sha: "ccc", head_sha: "ddd", source_key: "wf-newer",
        files_snapshot: [], metadata: {}
      )

      result = described_class.best_match_for(job_id: job.id, run_id: nil, workflow_id: workflow.id)
      expect(result).to eq(newer)
      expect(result).not_to eq(older)
    end

    it "returns nil when neither run_id nor workflow_id match anything" do
      expect(described_class.best_match_for(job_id: job.id, run_id: 999_999, workflow_id: 999_999)).to be_nil
    end
  end
end
