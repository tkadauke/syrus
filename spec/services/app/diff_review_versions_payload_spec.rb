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
      patch: "@@ -1 +1 @@\n-old\n+new",
      is_image: false
    )
  end

  it "flags a stored patch-less file as an image by extension" do
    version = DiffReviewVersions::Creator.call(
      job: job,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      files: [
        { path: "app/assets/images/logo.png", status: "added", additions: 0, deletions: 0, patch: nil }
      ]
    )

    show = described_class.show(version: version)

    expect(show[:files]).to contain_exactly(
      path: "app/assets/images/logo.png",
      status: "added",
      additions: 0,
      deletions: 0,
      patch: nil,
      is_image: true
    )
  end

  it "keeps a resumed Run's second, different commit range as its own distinguishable payload entry instead of a look-alike duplicate" do
    workflow = job.workflows.first
    run = job.runs.first

    first = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "main-sha",
      head_sha: "first-attempt-head",
      files: [
        { path: "app/models/user.rb", status: "modified", additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n-old\n+new" }
      ]
    )
    # Same Run persists again with a different head SHA -- the resumed/retried
    # Run scenario from DiffReviewVersions::Creator's docs: a Step re-running
    # against the same Run row committed a second time before the first
    # persisted diff was ever surfaced for review.
    second = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "main-sha",
      head_sha: "second-attempt-head",
      files: [
        { path: "app/models/user.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1 @@\n-old\n+new\n+newer" }
      ]
    )

    expect(second.id).not_to eq(first.id)
    expect(second.run_id).to eq(first.run_id)
    expect(second.head_sha).not_to eq(first.head_sha)

    index = described_class.index(job: job)
    payload_versions = index[:versions].select { |version| version[:run_id] == run.id }

    expect(payload_versions.map { |version| version[:id] }).to contain_exactly(first.id, second.id)
    expect(payload_versions.map { |version| version[:head_sha] }).to contain_exactly("first-attempt-head", "second-attempt-head")
    # The payload alone must carry enough to tell the two rows apart even
    # though they share a run_id -- the frontend derives its disambiguated
    # "RUN-<id> (<short sha>)" label from exactly these head_sha values.
    expect(payload_versions.map { |version| version[:head_sha] }.uniq.size).to eq(2)
  end

  it "marks the reusable All changes range as latest over narrower run checkpoints" do
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
    all_changes = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      base_sha: "branch-base",
      head_sha: "branch-head",
      base_ref: "main",
      head_ref: "syrus/issue-42",
      files: [
        { path: "plugins/design_docs/app/frontend/components/DesignDocsSurface.tsx", status: "modified", additions: 10, deletions: 0, patch: "@@ -1 +1,2 @@\n+ui" },
        { path: "app/services/step_dispatcher.rb", status: "modified", additions: 2, deletions: 0, patch: "@@ -1 +1,2 @@\n+backend" }
      ],
      label: "All changes",
      reason: "source_diff",
      metadata: { "range_kind" => "all_changes" }
    )
    expect(all_changes.version_index).to be > run_scoped.version_index

    index = described_class.index(job: job)

    expect(index[:latest_version_id]).to eq(all_changes.id)
  end
end
