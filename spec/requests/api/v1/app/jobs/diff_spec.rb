require "rails_helper"

RSpec.describe "App API pull request diff", type: :request do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job_with_run(
      repository: repo,
      issue_number: 42,
      branch_name: "syrus/issue-42",
      pr_number: 9,
      run_attrs: { head_sha: "a" * 40 }
    )
  end

  before { sign_in_as(user) }

  it "caps the proxy response" do
    stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/9")
      .to_return(status: 200, body: "x" * (10.megabytes + 1))

    get "/api/v1/app/jobs/#{job.id}/diff"

    expect(response).to have_http_status(:content_too_large)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("diff_too_large")
  end

  it "uses an immutable head-keyed ETag before proxying again" do
    request = stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/9")
      .to_return(status: 200, body: "diff --git a/a b/a\n")

    get "/api/v1/app/jobs/#{job.id}/diff"
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("immutable")
    etag = response.headers.fetch("ETag")

    get "/api/v1/app/jobs/#{job.id}/diff", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
    expect(request).to have_been_requested.once
  end

  it "does not treat a branch-name fallback as immutable" do
    job.runs.update_all(head_sha: nil)
    request = stub_request(:get, "https://api.github.com/repos/acme/widgets/pulls/9")
      .to_return(status: 200, body: "diff --git a/a b/a\n")

    get "/api/v1/app/jobs/#{job.id}/diff"
    etag = response.headers["ETag"]
    get "/api/v1/app/jobs/#{job.id}/diff", headers: { "If-None-Match" => etag.to_s }

    expect(response.headers["Cache-Control"]).not_to include("immutable")
    expect(request).to have_been_requested.twice
  end
end
