require "rails_helper"

RSpec.describe "App API job source browser", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job(repository: repo, issue_number: 42, branch_name: "syrus/issue-42") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  it "returns a source error without touching GitHub when credentials are missing" do
    user.update!(github_token: nil)

    expect(GithubClient).not_to receive(:for)

    get "/api/v1/app/jobs/#{job.id}/source"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["job_id"]).to eq(job.id)
    expect(body["source_error"]).to eq("GitHub token not configured. Add one in Settings to browse source.")
    expect(body["tree_items"]).to eq([])
    expect(body["file"]).to be_nil
    expect(body.dig("paths", "app_source_path")).to eq("/api/v1/app/jobs/#{job.id}/source")
  end

  it "returns refs, compact tree items, and selected file content" do
    user.update!(github_token: "ghp_test_token")
    commit_sha = "deadbeef12345678"

    stub_repository_history(repo, base: "main", head: "syrus/issue-42",
      commits: [ { sha: commit_sha, message: "Change user model", date: "2026-05-01T12:00:00Z" } ],
      merge_base_sha: "aabbccdd1234567")
    stub_repository_content(repo, ref: commit_sha, files: {
      "app/models/user.rb" => "class User\nend\n",
      "app/frontend/routes/Chat.tsx" => "x" * 256,
      "README.md" => "x" * 128
    })

    get "/api/v1/app/jobs/#{job.id}/source", params: { path: "app/models/user.rb" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["selected_ref"]).to eq(commit_sha)
    expect(body["merge_base_sha"]).to eq("aabbccdd1234567")
    expect(body["branch_commits"]).to contain_exactly(include(
      "sha" => commit_sha,
      "short_sha" => "deadbee",
      "message" => "Change user model",
      "date" => "2026-05-01T12:00:00Z"
    ))
    expect(body["tree_items"]).to contain_exactly(
      include("path" => "app/models/user.rb", "name" => "user.rb", "language" => "ruby", "size" => 15),
      include("path" => "app/frontend/routes/Chat.tsx", "name" => "Chat.tsx", "language" => "typescript", "size" => 256),
      include("path" => "README.md", "name" => "README.md", "language" => "markdown", "size" => 128)
    )
    expect(body["tree_truncated"]).to eq(false)
    expect(body["source_error"]).to be_nil
    expect(body["file_error"]).to be_nil
    expect(body["file"]).to include(
      "path" => "app/models/user.rb",
      "name" => "user.rb",
      "language" => "ruby",
      "content" => "class User\nend\n",
      "size" => 15,
      "truncated" => false
    )
  end

  it "reports a missing file without failing the tree" do
    user.update!(github_token: "ghp_test_token")
    job.update!(branch_name: nil)
    stub_repository_content(repo, files: { "README.md" => "hi" })

    get "/api/v1/app/jobs/#{job.id}/source", params: { path: "gone.rb" }

    body = parse_body
    expect(body["tree_items"].map { |item| item["path"] }).to eq([ "README.md" ])
    expect(body["file_error"]).to eq("File not found.")
  end

  it "shows a tree too large to list in full, flagged as truncated" do
    user.update!(github_token: "ghp_test_token")
    job.update!(branch_name: nil)
    stub_repository_content(repo, files: { "README.md" => "hi" }, truncated_tree: true)

    get "/api/v1/app/jobs/#{job.id}/source"

    body = parse_body
    expect(body["tree_truncated"]).to be(true)
    expect(body["tree_items"].map { |item| item["path"] }).to eq([ "README.md" ])
    expect(body["source_error"]).to be_nil
  end

  it "shows a source error when the repository cannot be read" do
    user.update!(github_token: "ghp_test_token")
    job.update!(branch_name: nil)
    stub_repository_content_failure(repo, RepositoryContent::Unavailable.new("rate limited"))

    get "/api/v1/app/jobs/#{job.id}/source"

    expect(parse_body["source_error"]).to eq("Could not load file tree: rate limited")
  end

  it "uses the default branch without comparing when the job has no branch" do
    user.update!(github_token: "ghp_test_token")
    job.update!(branch_name: nil)
    stub_repository_content(repo, files: { "README.md" => "x" * 64 })

    get "/api/v1/app/jobs/#{job.id}/source"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["selected_ref"]).to eq("main")
    expect(body["tree_items"]).to contain_exactly(include("path" => "README.md", "language" => "markdown"))
    expect(FakeRepositoryContentProvider.calls.map(&:first)).not_to include(:history)
  end

  it "does not expose another user's job" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job(repository: other_repo, issue_number: 99)

    get "/api/v1/app/jobs/#{other_job.id}/source"

    expect(response).to have_http_status(:not_found)
  end
end
