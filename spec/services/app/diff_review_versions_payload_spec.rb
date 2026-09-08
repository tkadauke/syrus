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

    index = described_class.index(job: job)
    show = described_class.show(version: version)

    expect(index[:latest_version_id]).to eq(version.id)
    expect(index[:versions]).to contain_exactly(include(
      id: version.id,
      version_index: 1,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      files_count: 1,
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
end
