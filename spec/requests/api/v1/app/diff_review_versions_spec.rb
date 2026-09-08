require "rails_helper"

RSpec.describe "App API diff review versions", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job_with_run(repository: repo, user: user, branch_name: "syrus/issue-42") }
  let(:version) do
    DiffReviewVersions::Creator.call(
      job: job,
      workflow: job.workflows.first,
      run: job.runs.first,
      base_sha: "aabbccdd1234567",
      head_sha: "deadbeef12345678",
      base_ref: "main",
      head_ref: "syrus/issue-42",
      files: [
        { path: "app/models/user.rb", status: "modified", additions: 4, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" }
      ]
    )
  end

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  it "lists versions for a visible job" do
    version

    get "/api/v1/app/jobs/#{job.id}/diff_review_versions"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["job_id"]).to eq(job.id)
    expect(body["latest_version_id"]).to eq(version.id)
    expect(body["versions"]).to contain_exactly(include(
      "id" => version.id,
      "version_index" => 1,
      "base_sha" => "aabbccdd1234567",
      "head_sha" => "deadbeef12345678",
      "files_count" => 1
    ))
  end

  it "fetches a selected version from its stored file snapshot" do
    expect(GithubClient).not_to receive(:for)

    get "/api/v1/app/jobs/#{job.id}/diff_review_versions/#{version.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "id" => version.id,
      "job_id" => job.id,
      "base_sha" => "aabbccdd1234567",
      "head_sha" => "deadbeef12345678",
      "default_ref" => "main",
      "diff_error" => nil
    )
    expect(body["files"]).to contain_exactly(include(
      "path" => "app/models/user.rb",
      "patch" => "@@ -1 +1 @@\n-old\n+new"
    ))
  end

  it "does not expose another user's versions" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job_with_run(repository: other_repo, user: other_user)
    other_version = DiffReviewVersions::Creator.call(job: other_job, base_sha: "base", head_sha: "head", files: [])

    get "/api/v1/app/jobs/#{other_job.id}/diff_review_versions/#{other_version.id}"

    expect(response).to have_http_status(:not_found)
  end
end
