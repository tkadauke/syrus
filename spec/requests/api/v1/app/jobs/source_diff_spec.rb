require "rails_helper"

RSpec.describe "App API job source diff browser", type: :request do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job(repository: repo, issue_number: 42, branch_name: "syrus/issue-42") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  it "returns source diff refs and changed files" do
    base_sha = "a" * 40
    head_sha = "b" * 40
    stub_repository_history(repo, base: "main", head: "syrus/issue-42",
      commits: [ { sha: head_sha, message: "Change source browser", date: "2026-05-01T12:00:00Z" } ],
      merge_base_sha: base_sha)
    stub_repository_diff(repo, base: base_sha, head: head_sha,
        files: [
          { path: "app/models/user.rb", status: "modified", additions: 4, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" },
          { path: "public/logo.png", status: "added", additions: 0, deletions: 0, patch: nil, patch_status: "binary" }
        ],
        truncated: false
      )
    resolved_base_sha = FakeRepositoryContentProvider.snapshots.fetch(repo.id).fetch(base_sha).fetch(:id)
    resolved_head_sha = FakeRepositoryContentProvider.snapshots.fetch(repo.id).fetch(head_sha).fetch(:id)

    get "/api/v1/app/jobs/#{job.id}/source_diff"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "job_id" => job.id,
      "base_ref" => base_sha,
      "head_ref" => head_sha,
      "base_sha" => resolved_base_sha,
      "head_sha" => resolved_head_sha,
      "merge_base_sha" => base_sha,
      "default_ref" => "main",
      "truncated" => false,
      "diff_error" => nil
    )
    expect(body["branch_commits"]).to contain_exactly(include("sha" => head_sha, "short_sha" => "bbbbbbb"))
    expect(body["files"]).to contain_exactly(
      include("path" => "app/models/user.rb", "status" => "modified", "additions" => 4, "deletions" => 1, "patch_bytes" => 21, "is_image" => false),
      include("path" => "public/logo.png", "status" => "added", "patch_status" => "binary", "is_image" => true)
    )
    expect(body["files"]).to all(satisfy { |file| !file.key?("patch") })
    expect(body).not_to have_key("versions")
    expect(response.headers["Cache-Control"]).not_to include("immutable")
    etag = response.headers.fetch("ETag")

    version = job.diff_review_versions.last
    DiffReviewComment.create!(
      job: job,
      diff_review_version: version,
      user: user,
      anchor_kind: "review",
      body: "Review-wide note"
    )
    get "/api/v1/app/jobs/#{job.id}/source_diff", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("version", "comments_count")).to eq(1)
    refreshed_etag = response.headers.fetch("ETag")

    get "/api/v1/app/jobs/#{job.id}/source_diff", headers: { "If-None-Match" => refreshed_etag }
    expect(response).to have_http_status(:not_modified)
    expect(body["version"]).to include(
      "version_index" => 1,
      "base_sha" => resolved_base_sha,
      "head_sha" => resolved_head_sha,
      "label" => "All changes",
      "reason" => "source_diff",
      "metadata" => { "range_kind" => "all_changes" }
    )
    expect(job.diff_review_versions.last.files_snapshot).to contain_exactly(
      include("path" => "app/models/user.rb", "patch" => "@@ -1 +1 @@\n-old\n+new"),
      include("path" => "public/logo.png", "patch" => nil, "patch_status" => "binary")
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

  it "loads and downloads an exact-revision per-file patch without storing it" do
    base = "a" * 40
    head = "b" * 40
    patch = "@@ -1 +1 @@\n-old\n+new\n"
    allow_any_instance_of(RepositoryContent::Reader).to receive(:file_patch)
      .with(base: have_attributes(id: base), head: have_attributes(id: head), path: "app/models/user.rb", previous_path: nil).and_return(patch)
    allow_any_instance_of(RepositoryContent::Reader).to receive(:file_patch_to) do |_reader, io, **|
      io.write(patch)
      io
    end

    get "/api/v1/app/jobs/#{job.id}/source_file_diff", params: { base: base, head: head, path: "app/models/user.rb" }
    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("patch" => patch, "rows" => 3)

    get "/api/v1/app/jobs/#{job.id}/source_file_diff_download", params: { base: base, head: head, path: "app/models/user.rb" }
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/x-diff")
    expect(response.headers["Content-Disposition"]).to include("attachment", "user.rb.diff")
    expect(job.diff_review_versions).to be_empty
  end

  it "loads and downloads a patch from an immutable review snapshot without a repository provider" do
    base = "c" * 40
    head = "d" * 40
    patch = "@@ -1 +1 @@\n-old preview\n+new preview\n"
    DiffReviewVersions::Creator.call(
      job: job,
      base_sha: base,
      head_sha: head,
      files: [ { path: "app/services/dashboard_payload.rb", status: "modified", patch: patch } ],
      truncated: false,
      reason: "diff_fixture"
    )

    expect(RepositoryContent).not_to receive(:for)

    get "/api/v1/app/jobs/#{job.id}/source_file_diff", params: { base: base, head: head, path: "app/services/dashboard_payload.rb" }
    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("patch" => patch)

    get "/api/v1/app/jobs/#{job.id}/source_file_diff_download", params: { base: base, head: head, path: "app/services/dashboard_payload.rb" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(patch)
  end

  it "loads a per-file patch using the refs returned for a development preview fixture" do
    base = "abc1234"
    head = "def5678"
    patch = "@@ -1 +1 @@\n-old preview\n+new preview\n"
    job.update!(diff_fixture: {
      base_ref: "main",
      head_ref: head,
      merge_base_sha: base,
      files: [ { path: "app/services/dashboard_payload.rb", status: "modified", patch: patch } ]
    })
    allow(Rails.env).to receive(:development?).and_return(true)

    get "/api/v1/app/jobs/#{job.id}/source_diff"
    expect(response).to have_http_status(:ok)
    source_diff = parse_body
    job.diff_review_versions.delete_all
    expect(RepositoryContent).not_to receive(:for)

    get "/api/v1/app/jobs/#{job.id}/source_file_diff", params: {
      base: source_diff.fetch("base_sha"),
      head: source_diff.fetch("head_sha"),
      path: source_diff.fetch("files").first.fetch("path")
    }
    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("patch" => patch)
    expect(response.headers["Cache-Control"]).not_to include("immutable")

    get "/api/v1/app/jobs/#{job.id}/source_file_diff_download", params: {
      base: source_diff.fetch("base_sha"),
      head: source_diff.fetch("head_sha"),
      path: source_diff.fetch("files").first.fetch("path")
    }
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(patch)
  end

  it "passes the previous path for renamed files and serializes UTF-8 patches" do
    patch = "@@ -1 +1 @@\n-café\n+Kaffee\n".dup.force_encoding(Encoding::BINARY)
    expect_any_instance_of(RepositoryContent::Reader).to receive(:file_patch)
      .with(base: have_attributes(id: "a" * 40), head: have_attributes(id: "b" * 40), path: "new.txt", previous_path: "old.txt")
      .and_return(patch.force_encoding(Encoding::UTF_8))

    get "/api/v1/app/jobs/#{job.id}/source_file_diff",
      params: { base: "a" * 40, head: "b" * 40, path: "new.txt", previous_path: "old.txt" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["patch"]).to include("café", "Kaffee")
  end

  it "rejects non-exact revisions and unsafe paths" do
    get "/api/v1/app/jobs/#{job.id}/source_file_diff", params: { base: "main", head: "b" * 40, path: "../secret" }
    expect(response).to have_http_status(:bad_request)
    expect(parse_body.dig("error", "code")).to eq("bad_request")

    get "/api/v1/app/jobs/#{job.id}/source_file_diff", params: { base: "main", head: "b" * 40, path: "safe.txt" }
    expect(response).to have_http_status(:bad_request)
  end

  it "does not expose another user's raw file diff" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private-diff")
    other_job = Factories.job(repository: other_repo, issue_number: 100)
    get "/api/v1/app/jobs/#{other_job.id}/source_file_diff_download", params: { base: "a" * 40, head: "b" * 40, path: "secret.txt" }
    expect(response).to have_http_status(:not_found)
  end

  it "reports the interactive row limit with an authenticated download URL" do
    allow_any_instance_of(RepositoryContent::Reader).to receive(:file_patch).and_return("+line\n" * 10_001)
    get "/api/v1/app/jobs/#{job.id}/source_file_diff", params: { base: "a" * 40, head: "b" * 40, path: "large.txt" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("10,000-line")
    expect(parse_body.dig("error", "download_url")).to include("source_file_diff_download")
  end

  it "applies the interactive byte limit to pathological long lines" do
    allow_any_instance_of(RepositoryContent::Reader).to receive(:file_patch).and_return("+#{'x' * (10.megabytes + 1)}")
    get "/api/v1/app/jobs/#{job.id}/source_file_diff", params: { base: "a" * 40, head: "b" * 40, path: "long.txt" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("interactive_diff_limit")
  end

  it "communicates the raw download ceiling" do
    allow_any_instance_of(RepositoryContent::Reader).to receive(:file_patch_to).and_raise(RepositoryContent::TooLarge)
    get "/api/v1/app/jobs/#{job.id}/source_file_diff_download", params: { base: "a" * 40, head: "b" * 40, path: "huge.txt" }
    expect(response).to have_http_status(:content_too_large)
    expect(parse_body.dig("error", "message")).to include("100 MiB")
  end
end
