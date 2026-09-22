require "rails_helper"

RSpec.describe "App API job source image", type: :request do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job(repository: repo, issue_number: 42, branch_name: "syrus/issue-42") }

  before { sign_in_as(user) }

  let(:png_bytes) { "\x89PNG\r\n\x1A\n".b }

  it "streams raw image bytes with the correct content type" do
    stub_repository_content(repo, ref: "syrus/issue-42", files: { "app/assets/images/logo.png" => png_bytes })

    get "/api/v1/app/jobs/#{job.id}/source_image", params: { path: "app/assets/images/logo.png", ref: "syrus/issue-42" }

    expect(response).to have_http_status(:ok)
    expect(response.content_type).to eq("image/png")
    expect(response.body.b).to eq(png_bytes)
  end

  it "returns 404 when the file does not exist at that ref" do
    stub_repository_content(repo, ref: "syrus/issue-42", files: {})

    get "/api/v1/app/jobs/#{job.id}/source_image", params: { path: "app/assets/images/missing.png", ref: "syrus/issue-42" }

    expect(response).to have_http_status(:not_found)
  end

  it "returns 404 for a ref the repository does not have" do
    stub_repository_content(repo, files: {})

    get "/api/v1/app/jobs/#{job.id}/source_image", params: { path: "logo.png", ref: "no-such-branch" }

    expect(response).to have_http_status(:not_found)
  end

  it "returns 503 rather than raising when the repository cannot be read" do
    stub_repository_content_failure(repo, RepositoryContent::Unavailable.new("rate limited"))

    get "/api/v1/app/jobs/#{job.id}/source_image", params: { path: "logo.png", ref: "main" }

    expect(response).to have_http_status(:service_unavailable)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("source_unavailable")
  end

  it "requires both path and ref" do
    get "/api/v1/app/jobs/#{job.id}/source_image", params: { path: "app/assets/images/logo.png" }

    expect(response).to have_http_status(:bad_request)
  end

  it "reports missing GitHub credentials instead of raising" do
    user.update!(github_token: nil)
    # Without credentials no content provider serves the repository.
    RepositoryContent.provider_classes_override = []

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
