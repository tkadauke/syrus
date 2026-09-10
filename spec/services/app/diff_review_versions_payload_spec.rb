require "rails_helper"

RSpec.describe App::DiffReviewVersionsPayload do
  let(:job) { Factories.job_with_run }

  it "lists versions and renders a selected version from the stored snapshot" do
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: job.workflows.first,
      run: job.runs.first,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      base_ref: "main",
      head_ref: "syrus/issue-42",
      files: [
        { path: "app/models/user.rb", status: "modified", additions: 4, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" }
      ],
      metadata: { "commit_count" => 1 }
    )
    version.diff_review_comments.create!(
      job: job,
      user: job.user,
      surface: "job_review_workspace",
      path: "app/models/user.rb",
      side: "right",
      new_line: 1,
      body: "Check this."
    )

    index = described_class.index(job: job)
    show = described_class.show(version: version)

    expect(index[:latest_version_id]).to eq(version.id)
    expect(index[:versions]).to contain_exactly(include(
      id: version.id,
      version_index: 1,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      files_count: 1,
      comments_count: 1,
      metadata: { "commit_count" => 1 }
    ))
    expect(show).to include(
      id: version.id,
      job_id: job.id,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      default_ref: job.repository.default_branch,
      diff_error: nil
    )
    expect(show[:files]).to contain_exactly(
      path: "app/models/user.rb",
      status: "modified",
      additions: 4,
      deletions: 1,
      patch: "@@ -1 +1 @@\n-old\n+new"
    )
  end

  it "prefers the newest run-scoped version as latest over newer no-run branch comparisons" do
    workflow = job.workflows.first
    run = job.runs.first
    run.update!(base_sha: "step-base", head_sha: "step-head")
    run_scoped = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "step-base",
      head_sha: "step-head",
      files: [
        { path: "app/services/step_dispatcher.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+backend" }
      ],
      reason: "initial"
    )
    synthetic = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      base_sha: "branch-base",
      head_sha: "branch-head",
      files: [
        { path: "plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx", status: "modified", additions: 10, deletions: 0, patch: "@@ -1 +1,2 @@\n+ui" }
      ],
      reason: "source_diff"
    )
    expect(synthetic.version_index).to be > run_scoped.version_index

    index = described_class.index(job: job)

    expect(index[:latest_version_id]).to eq(run_scoped.id)
  end
end
