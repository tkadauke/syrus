require "rails_helper"

RSpec.describe "App API job source diff browser", type: :request do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job(repository: repo, issue_number: 42, branch_name: "syrus/issue-42") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  it "returns source diff refs and changed files" do
    github = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: repo, user: user).and_return(github)
    allow(github).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/issue-42")
      .and_return(
        commits: [
          { sha: "deadbeef12345678", short_sha: "deadbee", message: "Change source browser", date: Time.zone.parse("2026-05-01T12:00:00Z") }
        ],
        merge_base_sha: "aabbccdd1234567"
      )
    allow(github).to receive(:compare_files)
      .with("acme/widgets", "aabbccdd1234567", "deadbeef12345678")
      .and_return(
        files: [
          { path: "app/models/user.rb", status: "modified", additions: 4, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" },
          { path: "public/logo.png", status: "added", additions: 0, deletions: 0, patch: nil }
        ],
        truncated: false
      )

    get "/api/v1/app/jobs/#{job.id}/source_diff"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "job_id" => job.id,
      "base_ref" => "aabbccdd1234567",
      "head_ref" => "deadbeef12345678",
      "merge_base_sha" => "aabbccdd1234567",
      "default_ref" => "main",
      "truncated" => false,
      "diff_error" => nil
    )
    expect(body["branch_commits"]).to contain_exactly(include("sha" => "deadbeef12345678", "short_sha" => "deadbee"))
    expect(body["files"]).to contain_exactly(
      include("path" => "app/models/user.rb", "status" => "modified", "additions" => 4, "deletions" => 1, "patch" => "@@ -1 +1 @@\n-old\n+new"),
      include("path" => "public/logo.png", "status" => "added", "patch" => nil)
    )
  end

  it "returns 404 for an unknown job" do
    get "/api/v1/app/jobs/999999/source_diff"

    expect(response).to have_http_status(:not_found)
  end

  it "does not expose another user's job" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job(repository: other_repo, issue_number: 99)

    get "/api/v1/app/jobs/#{other_job.id}/source_diff"

    expect(response).to have_http_status(:not_found)
  end
end
