require "rails_helper"

RSpec.describe "App API job source image", type: :request do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job(repository: repo, issue_number: 42, branch_name: "syrus/issue-42") }

  before { sign_in_as(user) }

  it "streams raw image bytes with the correct content type" do
    github = instance_double(GithubClient)
    png_bytes = "\x89PNG\r\n\x1A\n".b
    allow(GithubClient).to receive(:for).with(repository: repo, user: user).and_return(github)
    allow(github).to receive(:binary_file_content_at)
      .with("acme/widgets", "app/assets/images/logo.png", "deadbeef12345678")
      .and_return(content: png_bytes, size: png_bytes.bytesize)

    get "/api/v1/app/jobs/#{job.id}/source_image", params: { path: "app/assets/images/logo.png", ref: "deadbeef12345678" }

    expect(response).to have_http_status(:ok)
    expect(response.content_type).to eq("image/png")
    expect(response.body.b).to eq(png_bytes)
  end

  it "returns 404 when the file does not exist at that ref" do
    github = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: repo, user: user).and_return(github)
    allow(github).to receive(:binary_file_content_at)
      .with("acme/widgets", "app/assets/images/missing.png", "deadbeef12345678")
      .and_return(nil)

    get "/api/v1/app/jobs/#{job.id}/source_image", params: { path: "app/assets/images/missing.png", ref: "deadbeef12345678" }

    expect(response).to have_http_status(:not_found)
  end

  it "requires both path and ref" do
    get "/api/v1/app/jobs/#{job.id}/source_image", params: { path: "app/assets/images/logo.png" }

    expect(response).to have_http_status(:bad_request)
  end

  it "reports missing GitHub credentials instead of raising" do
    user.update!(github_token: nil)

    get "/api/v1/app/jobs/#{job.id}/source_image", params: { path: "app/assets/images/logo.png", ref: "deadbeef12345678" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("no_github_token")
  end

  it "does not expose another user's job" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job(repository: other_repo, issue_number: 99)

    get "/api/v1/app/jobs/#{other_job.id}/source_image", params: { path: "logo.png", ref: "main" }

    expect(response).to have_http_status(:not_found)
  end
end
