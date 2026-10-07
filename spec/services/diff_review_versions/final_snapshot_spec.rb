require "rails_helper"

RSpec.describe DiffReviewVersions::FinalSnapshot do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }

  def closed_job_with_run(diff: nil, base_sha: "branch-base", head_sha: "branch-head")
    job = Factories.job_with_run(
      user: user,
      repository: repo,
      branch_name: "syrus/issue-42",
      workflow_attrs: { state: "succeeded" },
      step_attrs: { kind: "implement", state: "succeeded" },
      run_attrs: {
        state: "succeeded",
        base_sha: base_sha,
        head_sha: head_sha,
        step_agent_diff: diff
      }
    )
    job.update_columns(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)
    job
  end

  it "materializes a final All changes version from the live branch before branch cleanup" do
    job = closed_job_with_run
    stub_repository_history(repo, base: "main", head: "syrus/issue-42",
      commits: [ { sha: "branch-head", message: "Implement", date: "2026-05-01T12:00:00Z" } ],
      merge_base_sha: "branch-base")
    stub_repository_diff(repo, base: "branch-base", head: "branch-head", files: [
      { path: "app/models/widget.rb", status: "modified", additions: 2, deletions: 1, patch: "@@ -1 +1,2 @@\n+new" }
    ])

    result = described_class.materialize(job: job, user: user)

    expect(result.status).to eq(:created)
    expect(result.version).to have_attributes(
      label: "All changes",
      reason: "source_diff",
      source_key: described_class::FINAL_SOURCE_KEY,
      base_sha: "branch-base",
      head_sha: "branch-head",
      base_ref: "main",
      head_ref: "syrus/issue-42"
    )
    expect(result.version.files_snapshot).to contain_exactly(include(
      "path" => "app/models/widget.rb",
      "status" => "modified"
    ))
  end

  it "reuses an existing final snapshot without creating duplicates" do
    job = closed_job_with_run
    existing = DiffReviewVersion.create!(
      job: job,
      version_index: DiffReviewVersion.next_index_for(job),
      base_sha: "branch-base",
      head_sha: "branch-head",
      source_key: described_class::FINAL_SOURCE_KEY,
      label: "All changes",
      reason: "source_diff",
      files_snapshot: [
        { "path" => "app/models/widget.rb", "status" => "modified", "additions" => 1, "deletions" => 0, "patch" => "@@ -1 +1 @@" }
      ],
      metadata: { "range_kind" => "all_changes" }
    )

    result = described_class.materialize(job: job, user: user)

    expect(result.status).to eq(:reused)
    expect(result.version).to eq(existing)
    expect(job.diff_review_versions.count).to eq(1)
  end
end
