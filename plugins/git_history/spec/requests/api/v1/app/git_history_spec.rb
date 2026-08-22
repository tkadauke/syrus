require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe "API: /api/v1/app/repositories/:repository_id/git_history", type: :request do
  let(:syrus_data_root) { Pathname.new(Dir.mktmpdir("syrus-data")) }
  let(:origin_dir) { Pathname.new(Dir.mktmpdir("syrus-origin")) }
  let(:owner) { Factories.user }
  let(:collaborator) { Factories.user }
  let(:unrelated_user) { Factories.user }
  let(:repository) { Factories.repository(user: owner, default_branch: "main") }

  def parse_body = JSON.parse(response.body)

  before do
    ENV["SYRUS_DATA_ROOT"] = syrus_data_root.to_s
    repository.repository_memberships.create!(user: collaborator, role: "collaborator")
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(syrus_data_root)
    FileUtils.rm_rf(origin_dir)
  end

  def commit!(message)
    FileUtils.mkdir_p(origin_dir) unless origin_dir.exist?
    unless origin_dir.join(".git").exist?
      `git init -b main #{origin_dir} 2>&1`
      `git -C #{origin_dir} config user.email "author@example.com" 2>&1`
      `git -C #{origin_dir} config user.name "Author Name" 2>&1`
    end
    `touch #{origin_dir}/file-#{SecureRandom.hex(4)}.txt`
    `git -C #{origin_dir} add . 2>&1`
    `git -C #{origin_dir} commit -m "#{message}" 2>&1`
    `git -C #{origin_dir} rev-parse HEAD 2>&1`.strip
  end

  def bare_clone!
    path = RepositoryBareClone.path_for(repository)
    FileUtils.mkdir_p(path.dirname)
    output = `git clone --bare #{origin_dir} #{path} 2>&1`
    raise "bare clone failed: #{output}" unless $?.success?
  end

  it "rejects a user with no relationship to the repository" do
    sign_in_as(unrelated_user)

    get "/api/v1/app/repositories/#{repository.id}/git_history/commits"

    expect(response).to have_http_status(:not_found)
  end

  it "allows the repository owner and a RepositoryMembership collaborator" do
    commit!("initial")
    bare_clone!

    sign_in_as(owner)
    get "/api/v1/app/repositories/#{repository.id}/git_history/commits"
    expect(response).to have_http_status(:ok)

    sign_in_as(collaborator)
    get "/api/v1/app/repositories/#{repository.id}/git_history/commits"
    expect(response).to have_http_status(:ok)
  end

  it "reports available: false when the bare clone has not been synced yet" do
    sign_in_as(owner)

    get "/api/v1/app/repositories/#{repository.id}/git_history/commits"

    expect(response).to have_http_status(:ok)
    expect(parse_body["available"]).to eq(false)
    expect(parse_body["commits"]).to eq([])
  end

  it "attributes a syrus_landed commit to its Job, Epic, creating user, and GitHub issue origin" do
    sha = commit!("fix the thing")
    bare_clone!
    epic = Factories.epic(repository: repository, user: owner)
    job = Factories.job_record(
      repository: repository, user: owner, kind: "issue", landed_sha: sha,
      issue_number: 12, input_source: repository.github_input_source, epic: epic
    )

    sign_in_as(owner)
    get "/api/v1/app/repositories/#{repository.id}/git_history/commits"

    commit = parse_body["commits"].find { |c| c["sha"] == sha }
    expect(commit["classification"]).to eq("syrus_landed")
    expect(commit.dig("job", "id")).to eq(job.id)
    expect(commit.dig("epic", "id")).to eq(epic.id)
    expect(commit.dig("user", "id")).to eq(owner.id)
    expect(commit.dig("origin", "type")).to eq("github_issue")
    expect(commit.dig("origin", "issue_number")).to eq(12)
  end

  it "attributes a syrus_landed commit to its originating cron ScheduledTask" do
    sha = commit!("nightly sweep")
    bare_clone!
    scheduled_task = ScheduledTask.create!(
      user: owner, repository: repository,
      name: "Nightly sweep", prompt: "Do the thing",
      kind: "cron", cron_expression: "0 * * * *",
      minute_offset: 1, pr_pileup_policy: "skip"
    )
    Factories.job_record(
      repository: repository, user: owner, kind: "cron", landed_sha: sha,
      issue_number: nil, scheduled_task: scheduled_task
    )

    sign_in_as(owner)
    get "/api/v1/app/repositories/#{repository.id}/git_history/commits"

    commit = parse_body["commits"].find { |c| c["sha"] == sha }
    expect(commit.dig("origin", "type")).to eq("cron")
    expect(commit.dig("origin", "scheduled_task", "name")).to eq("Nightly sweep")
  end

  it "attributes a syrus_landed commit to its originating chat when the current user can access that chat" do
    sha = commit!("ship it")
    bare_clone!
    job = Factories.job_record(repository: repository, user: owner, kind: "direct", landed_sha: sha, issue_number: nil)
    chat_session = ChatSession.create!(user: owner, repository: repository, title: "Ship the thing")
    chat_session.chat_attachments.create!(attachable: job)

    sign_in_as(owner)
    get "/api/v1/app/repositories/#{repository.id}/git_history/commits"

    commit = parse_body["commits"].find { |c| c["sha"] == sha }
    expect(commit.dig("origin", "type")).to eq("chat")
    expect(commit.dig("origin", "chat_session_id")).to eq(chat_session.id)
    expect(commit.dig("origin", "chat_title")).to eq("Ship the thing")
  end

  it "redacts the chat reference when the current user cannot access the originating chat" do
    sha = commit!("ship it quietly")
    bare_clone!
    job = Factories.job_record(repository: repository, user: owner, kind: "direct", landed_sha: sha, issue_number: nil)
    chat_session = ChatSession.create!(user: owner, repository: repository, title: "Private planning")
    chat_session.chat_attachments.create!(attachable: job)

    # Collaborator has repo access (can hit the endpoint) but is not a
    # participant of the owner's chat, so the chat reference must not leak.
    sign_in_as(collaborator)
    get "/api/v1/app/repositories/#{repository.id}/git_history/commits"

    commit = parse_body["commits"].find { |c| c["sha"] == sha }
    expect(commit.dig("origin", "type")).to eq("chat")
    expect(commit["origin"]).not_to have_key("chat_session_id")
    expect(commit["origin"]).not_to have_key("chat_title")
  end

  it "attributes an externally-opened PR commit as external_pr, not syrus_landed" do
    sha = commit!("external contribution")
    bare_clone!
    job = Job.create!(
      user: owner, repository: repository,
      kind: "external_pr", state: "implemented",
      issue_number: nil, external_pr_number: 55, external_pr_author: "octocat",
      landed_sha: sha
    )

    sign_in_as(owner)
    get "/api/v1/app/repositories/#{repository.id}/git_history/commits"

    commit = parse_body["commits"].find { |c| c["sha"] == sha }
    expect(commit["classification"]).to eq("external_pr")
    expect(commit.dig("job", "id")).to eq(job.id)
    expect(commit["pr_number"]).to eq(55)
    expect(commit["github_author"]).to eq("octocat")
  end

  it "attributes a raw push with no Job as external_push, surfacing git author/committer info" do
    sha = commit!("raw push straight to main")
    bare_clone!

    sign_in_as(owner)
    get "/api/v1/app/repositories/#{repository.id}/git_history/commits"

    commit = parse_body["commits"].find { |c| c["sha"] == sha }
    expect(commit["classification"]).to eq("external_push")
    expect(commit.dig("author", "name")).to eq("Author Name")
    expect(commit.dig("author", "email")).to eq("author@example.com")
    expect(commit).not_to have_key("job")
  end
end
