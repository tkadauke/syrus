require "rails_helper"

RSpec.describe "API: repository recommendations", type: :request do
  let!(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", ci_health: "not_configured") }
  let(:client) { instance_double(GithubClient) }

  before do
    allow(App::PreviewAvailability).to receive(:configured?).and_return(false)
    allow(Feature).to receive(:visual_review_enabled?).and_return(false)
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:file_content_at).and_return(nil)
    allow(client).to receive(:file_tree_at).and_return(items: [], truncated: false)
  end

  def parse_body
    JSON.parse(response.body)
  end

  def bearer_headers(user)
    { "Authorization" => "Bearer #{user.generate_api_token!}" }
  end

  # `.syrus.yml` and the repo file tree are read over the GitHub API, not the
  # repository's local bare clone — the web tier that serves this request
  # doesn't share the worker's on-disk clone.
  def stub_repo_files(paths)
    allow(client).to receive(:file_tree_at)
      .with(repository.slug, repository.default_branch)
      .and_return(items: paths.map { |path| { path: path, size: 0 } }, truncated: false)
  end

  it "includes recommended actions in the repository detail payload" do
    stub_repo_files(%w[Gemfile])
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["recommended_actions"]).to include(include(
      "id" => "syrus_prepare",
      "dismissal_key" => "repository:#{repository.id}:feature_recommendation:syrus_prepare:v1"
    ))
  end

  it "creates a direct Job from a currently applicable server-owned job CTA" do
    stub_repo_files(%w[Gemfile])
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/recommendations/github_actions_ci", as: :json
    }.to change { repository.jobs.where(kind: "direct").count }.by(1)

    expect(response).to have_http_status(:created)
    job = repository.jobs.where(kind: "direct").order(:id).last
    expect(job.issue_title).to eq("Add GitHub Actions CI")
    expect(job.issue_body).to include("CI")
    expect(parse_body["redirect_to"]).to eq("/jobs/#{job.id}")
  end

  it "allows write-tier repository members to create recommendation jobs" do
    writer = Factories.user(global_role: "user")
    repository.repository_memberships.create!(user: writer, role: "write")
    stub_repo_files(%w[Gemfile])

    expect {
      post "/api/v1/app/repositories/#{repository.id}/recommendations/github_actions_ci", headers: bearer_headers(writer), as: :json
    }.to change { repository.jobs.where(kind: "direct").count }.by(1)

    expect(response).to have_http_status(:created)
    expect(repository.jobs.where(kind: "direct").order(:id).last.user).to eq(writer)
  end

  it "rejects recommendation jobs for read-only repository members" do
    reader = Factories.user(global_role: "user")
    repository.repository_memberships.create!(user: reader, role: "read")
    stub_repo_files(%w[Gemfile])

    expect {
      post "/api/v1/app/repositories/#{repository.id}/recommendations/github_actions_ci", headers: bearer_headers(reader), as: :json
    }.not_to change { repository.jobs.count }

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "applies a low-risk repository toggle and returns the updated detail payload" do
    repository.update!(prepare_enabled: false)
    sign_in_as(user)

    post "/api/v1/app/repositories/#{repository.id}/recommendations/enable_prepare", as: :json

    expect(response).to have_http_status(:ok)
    expect(repository.reload.prepare_enabled).to be(true)
    expect(parse_body.dig("repository", "id")).to eq(repository.id)
    expect(parse_body["message"]).to eq("Repository setting enabled.")
  end

  it "rejects repository setting toggles for write-tier repository members" do
    writer = Factories.user(global_role: "user")
    repository.repository_memberships.create!(user: writer, role: "write")
    repository.update!(prepare_enabled: false)

    post "/api/v1/app/repositories/#{repository.id}/recommendations/enable_prepare", headers: bearer_headers(writer), as: :json

    expect(response).to have_http_status(:forbidden)
    expect(repository.reload.prepare_enabled).to be(false)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "rejects repository setting toggles for read-only repository members" do
    reader = Factories.user(global_role: "user")
    repository.repository_memberships.create!(user: reader, role: "read")
    repository.update!(prepare_enabled: false)

    post "/api/v1/app/repositories/#{repository.id}/recommendations/enable_prepare", headers: bearer_headers(reader), as: :json

    expect(response).to have_http_status(:forbidden)
    expect(repository.reload.prepare_enabled).to be(false)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "rejects stale or inapplicable recommendation actions" do
    stub_repo_files([".github/workflows/ci.yml"])
    sign_in_as(user)

    post "/api/v1/app/repositories/#{repository.id}/recommendations/github_actions_ci", as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
  end
end
