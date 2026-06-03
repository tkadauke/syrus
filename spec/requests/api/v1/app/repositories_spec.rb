require "rails_helper"

RSpec.describe "API: /api/v1/app/repositories", type: :request do
  let(:user) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  def fake_issue(number:, title: "Fix something", state: "open", labels: [], body: nil)
    double(
      "issue",
      number: number,
      title: title,
      state: state,
      html_url: "https://github.com/acme/widgets/issues/#{number}",
      body: body,
      created_at: 1.day.ago,
      user: double("user", login: "alice"),
      labels: labels.map { |name| double("label", name: name, color: "0075ca") }
    )
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/repositories"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "lists active and archived repositories for the signed-in user" do
    sign_in_as(user)
    active = Factories.repository(
      user: user,
      owner: "acme",
      name: "widgets",
      default_branch: "main",
      trigger_label: "syrus",
      polling_enabled: true,
      agent_provider: "codex",
      last_poll_status: "ok",
      last_poll_started_at: Time.zone.parse("2026-05-30 12:00:00")
    )
    archived = Factories.repository(user: user, owner: "old", name: "repo")
    archived.archive!
    Factories.repository(user: Factories.user, owner: "other", name: "private")

    get "/api/v1/app/repositories"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["active_repositories"]).to contain_exactly(
      include(
        "id" => active.id,
        "slug" => "acme/widgets",
        "owner_user" => include("id" => user.id, "email_address" => user.email_address),
        "default_branch" => "main",
        "trigger_label" => "syrus",
        "polling_enabled" => true,
        "agent_provider_label" => "Codex",
        "last_poll_status" => "ok",
        "repository_path" => repository_path(active),
        "edit_repository_path" => edit_repository_path(active)
      )
    )
    expect(body["archived_repositories"]).to contain_exactly(
      include("id" => archived.id, "slug" => "old/repo", "archived" => true)
    )
    expect(body.to_s).not_to include("other/private")
    expect(body["new_repository_path"]).to eq(new_repository_path)
  end

  it "allows two users to configure the same GitHub slug independently" do
    Factories.repository(user: Factories.user, owner: "acme", name: "widgets")
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories", params: {
        repository: {
          owner: "acme",
          name: "widgets",
          default_branch: "main",
          trigger_label: "syrus",
          polling_enabled: true,
          prepare_enabled: true
        }
      }
    }.to change { user.repositories.where(owner: "acme", name: "widgets").count }.from(0).to(1)

    expect(response).to have_http_status(:created)
    expect(parse_body.dig("repository", "owner_user")).to include(
      "id" => user.id,
      "email_address" => user.email_address
    )
  end

  it "rejects duplicate GitHub slugs for the same user with a clear owner-scoped message" do
    sign_in_as(user)
    Factories.repository(user: user, owner: "acme", name: "widgets")

    expect {
      post "/api/v1/app/repositories", params: {
        repository: {
          owner: "acme",
          name: "widgets",
          default_branch: "main",
          trigger_label: "syrus",
          polling_enabled: true,
          prepare_enabled: true
        }
      }
    }.not_to change(Repository, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include(
      "Name has already been configured for this Syrus user and GitHub owner"
    )
  end

  it "returns the new repository form payload" do
    sign_in_as(user)
    user.update!(agent_provider: "codex")

    get "/api/v1/app/repositories/new"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("repository", "default_branch")).to eq("main")
    expect(body.dig("repository", "upstream_owner")).to eq("")
    expect(body.dig("repository", "upstream_name")).to eq("")
    expect(body.dig("repository", "upstream_default_branch")).to eq("")
    expect(body.dig("repository", "trigger_label")).to eq("syrus")
    expect(body.dig("repository", "polling_enabled")).to eq(true)
    expect(body["configured_agent_providers"]).to include(
      { "value" => "codex", "label" => "Codex" },
      { "value" => "claude", "label" => "Claude Code" }
    )
    expect(body["user_agent_provider_label"]).to eq("Codex")
    expect(body["auto_approve_modes"]).to include(include("value" => "if_graders_pass"))
    expect(body["repositories_path"]).to eq(repositories_path)
  end

  it "returns the edit repository form payload" do
    sign_in_as(user)
    repository = Factories.repository(
      user: user,
      owner: "acme",
      name: "widgets",
      default_branch: "trunk",
      upstream_owner: "rails",
      upstream_name: "rails",
      upstream_default_branch: "main",
      trigger_label: "delegate",
      polling_enabled: false,
      prepare_enabled: false,
      pr_cost_footer_enabled: false,
      auto_merge_enabled: true,
      agent_provider: "codex",
      auto_approve_mode: "if_graders_pass",
      github_owner_id: 123,
      github_repository_id: 456
    )

    get "/api/v1/app/repositories/#{repository.id}/edit"

    expect(response).to have_http_status(:ok)
    expect(parse_body["repository"]).to include(
      "id" => repository.id,
      "owner" => "acme",
      "name" => "widgets",
      "slug" => "acme/widgets",
      "default_branch" => "trunk",
      "upstream_owner" => "rails",
      "upstream_name" => "rails",
      "upstream_default_branch" => "main",
      "trigger_label" => "delegate",
      "polling_enabled" => false,
      "prepare_enabled" => false,
      "pr_cost_footer_enabled" => false,
      "auto_merge_enabled" => true,
      "agent_provider" => "codex",
      "auto_approve_mode" => "if_graders_pass",
      "github_owner_id" => 123,
      "github_repository_id" => 456,
      "repository_path" => repository_path(repository)
    )
  end

  it "returns the repository detail payload" do
    sign_in_as(user)
    AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
    repository = Factories.repository(
      user: user,
      owner: "acme",
      name: "widgets",
      trigger_label: "syrus",
      agent_provider: "codex",
      github_owner_id: 100,
      github_repository_id: 200
    )
    active_note = repository.repository_notes.create!(body: "Use staging for smoke tests.", author: "operator")
    repository.repository_notes.create!(body: "Removed context.", author: "agent", removed_at: Time.current)
    failed = Factories.job(repository: repository, issue_number: 1, issue_title: "Fix forum")
    failed.current_run.update!(state: "failed", finished_at: Time.current)
    failed.latest_workflow.update!(
      state: "failed",
      failure_count: 3,
      artifacts: { "failure_classification" => "agent_timeout", "auto_retry_exhausted" => true }
    )
    running = Factories.job(repository: repository, issue_number: 2, issue_title: "Survey aqueduct")
    running.current_run.update!(state: "running", started_at: Time.current)
    queued = Factories.job(repository: repository, issue_number: 3, issue_title: "Polish marble")
    queued.current_run.update!(state: "queued")
    other_repository = Factories.repository(user: user, owner: "acme", name: "other")
    Factories.job(repository: other_repository, issue_number: 99, issue_title: "Private")

    get "/api/v1/app/repositories/#{repository.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("repository", "slug")).to eq("acme/widgets")
    expect(body.dig("repository", "owner_user")).to include(
      "id" => user.id,
      "email_address" => user.email_address
    )
    expect(body.dig("repository", "agent_provider_label")).to eq("Codex")
    expect(body.dig("repository", "github_url")).to eq("https://github.com/acme/widgets")
    expect(body["tabs"]).to include(
      { "key" => "overview", "label" => "Overview", "path" => repository_path(repository) },
      { "key" => "github_issues", "label" => "GitHub Issues", "path" => repository_path(repository, tab: "github_issues") },
      { "key" => "context", "label" => "Context", "path" => repository_path(repository, tab: "context") },
      { "key" => "documents", "label" => "Documents", "path" => repository_documents_path(repository) },
      { "key" => "scheduled_tasks", "label" => "Scheduled Tasks", "path" => repository_scheduled_tasks_path(repository) }
    )
    expect(body["counts"]).to include("running" => 1, "queued" => 1, "failed_7d" => 1)
    expect(body["retry_failed_jobs"]).to include("count" => 1, "agent_provider_label" => "Codex")
    expect(body["credential_status"]).to include(
      "mode" => "pat",
      "label" => "PAT fallback: no active App installation",
      "github_app_registered" => true,
      "install_url" => "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=100&repository_ids[]=200"
    )
    expect(body["notes"]).to contain_exactly(include(
      "id" => active_note.id,
      "body" => "Use staging for smoke tests.",
      "app_delete_path" => "/api/v1/app/repositories/#{repository.id}/notes/#{active_note.id}"
    ))
    expect(body["jobs"]).to include(
      include(
        "id" => failed.id,
        "issue_title" => "Fix forum",
        "source" => include("label" => "#1"),
        "retry_state" => include(
          "classification" => "agent_timeout",
          "auto_retry_exhausted" => true,
          "state_label" => "Auto-retry exhausted"
        )
      ),
      include("id" => running.id, "issue_title" => "Survey aqueduct"),
      include("id" => queued.id, "issue_title" => "Polish marble")
    )
    expect(body.to_s).not_to include("Private")
    expect(body["pagination"]).to include("page" => 1, "total_jobs" => 3, "total_pages" => 1)
    expect(body["paths"]).to include(
      "new_job_path" => new_job_path(repository_id: repository.id),
      "edit_repository_path" => edit_repository_path(repository),
      "app_poll_repository_path" => "/api/v1/app/repositories/#{repository.id}/poll",
      "app_archive_repository_path" => "/api/v1/app/repositories/#{repository.id}/archive",
      "app_retry_failed_jobs_repository_path" => "/api/v1/app/repositories/#{repository.id}/retry_failed_jobs",
      "app_repository_notes_path" => "/api/v1/app/repositories/#{repository.id}/notes"
    )
    expect(body["paths"].keys).not_to include("poll_repository_path", "archive_repository_path", "retry_failed_jobs_repository_path")
  end

  it "creates and removes repository notes through the app API" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")

    expect {
      post "/api/v1/app/repositories/#{repository.id}/notes", params: { repository_note: { body: "Use staging for smoke tests." } }
    }.to change { repository.repository_notes.active.count }.by(1)

    expect(response).to have_http_status(:ok)
    note = repository.repository_notes.active.sole
    expect(note.author).to eq("operator")
    expect(parse_body["message"]).to eq("Repository context pinned.")
    expect(parse_body["notes"]).to contain_exactly(include(
      "body" => "Use staging for smoke tests.",
      "app_delete_path" => "/api/v1/app/repositories/#{repository.id}/notes/#{note.id}"
    ))

    expect {
      delete "/api/v1/app/repositories/#{repository.id}/notes/#{note.id}"
    }.to change { repository.repository_notes.active.count }.from(1).to(0)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Repository context removed.")
    expect(parse_body["notes"]).to eq([])
    expect(note.reload).to be_removed
  end

  it "rejects blank repository notes through the app API" do
    sign_in_as(user)
    repository = Factories.repository(user: user)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/notes", params: { repository_note: { body: " " } }
    }.not_to change(RepositoryNote, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Context cannot be blank.")
  end

  it "does not expose another user's repository detail" do
    sign_in_as(user)
    foreign = Factories.repository(user: Factories.user)

    get "/api/v1/app/repositories/#{foreign.id}"

    expect(response).to have_http_status(:not_found)
  end

  it "returns repository GitHub issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    issue = fake_issue(number: 7, title: "Fix the forum", labels: [ "syrus", "bug" ], body: "Line one\nLine two")
    client = instance_double(GithubClient)
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([ issue ])
    allow(GithubClient).to receive(:for).and_return(client)

    get "/api/v1/app/repositories/#{repository.id}/issues", params: { state: "closed" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["state"]).to eq("closed")
    expect(body["issue_count"]).to eq(1)
    expect(body["issues"]).to contain_exactly(include(
      "number" => 7,
      "title" => "Fix the forum",
      "body_excerpt" => "Line one Line two",
      "user_login" => "alice",
      "delegated" => true,
      "labels" => include({ "name" => "bug", "color" => "0075ca" })
    ))
    expect(body.dig("paths", "app_delegate_issue_path")).to eq("/api/v1/app/repositories/#{repository.id}/issues/delegate")
    expect(body.dig("state_paths", "open")).to eq(repository_path(repository, tab: "github_issues", state: "open"))
  end

  it "returns an issues payload error when GitHub credentials are missing" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    allow(GithubClient).to receive(:for).and_raise(ArgumentError)

    get "/api/v1/app/repositories/#{repository.id}/issues"

    expect(response).to have_http_status(:ok)
    expect(parse_body["issues"]).to eq([])
    expect(parse_body["error_message"]).to include("No GitHub token configured")
  end

  it "comments on a GitHub issue" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    client = instance_double(GithubClient)
    expect(client).to receive(:add_issue_comment).with("acme/widgets", 7, "Looks good", on_behalf_of: user)
    expect(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/comment", params: {
      issue_number: 7,
      comment_body: "Looks good",
      state: "open"
    }

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Comment added to #7.")
  end

  it "rejects blank GitHub issue comments" do
    sign_in_as(user)
    repository = Factories.repository(user: user)

    post "/api/v1/app/repositories/#{repository.id}/issues/comment", params: {
      issue_number: 7,
      comment_body: " "
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("blank")
  end

  it "closes and delegates GitHub issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    client = instance_double(GithubClient)
    expect(client).to receive(:close_issue).with("acme/widgets", 12)
    expect(client).to receive(:add_label_to_issue).with("acme/widgets", 13, "syrus")
    expect(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "open").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/close", params: { issue_number: 12, state: "open" }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Issue #12 closed.")

    post "/api/v1/app/repositories/#{repository.id}/issues/delegate", params: { issue_number: 13, state: "open" }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Issue #13 delegated to Syrus.")
  end

  it "bulk closes and delegates selected GitHub issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")
    client = instance_double(GithubClient)
    expect(client).to receive(:add_label_to_issue).with("acme/widgets", 4, "syrus")
    expect(client).to receive(:add_label_to_issue).with("acme/widgets", 8, "syrus")
    expect(client).to receive(:close_issue).with("acme/widgets", 4)
    expect(client).to receive(:list_all_issues).twice.with("acme/widgets", state: "open").and_return([])
    allow(GithubClient).to receive(:for).and_return(client)

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: {
      issue_numbers: %w[4 8],
      bulk_action: "delegate",
      state: "open"
    }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("2 issues delegated to Syrus.")

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: {
      issue_numbers: %w[4 4 invalid],
      bulk_action: "close",
      state: "open"
    }
    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("1 issue closed.")
  end

  it "rejects bulk GitHub issue commands without selected issues" do
    sign_in_as(user)
    repository = Factories.repository(user: user)

    post "/api/v1/app/repositories/#{repository.id}/issues/bulk", params: { bulk_action: "delegate" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("Select")
  end

  it "creates repositories" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories", params: {
        repository: {
          owner: "acme",
          name: "widgets",
          default_branch: "main",
          upstream_owner: "rails",
          upstream_name: "rails",
          upstream_default_branch: "main",
          trigger_label: "syrus",
          polling_enabled: "1",
          prepare_enabled: "0",
          pr_cost_footer_enabled: "0",
          auto_merge_enabled: "1",
          agent_provider: "codex",
          auto_approve_mode: "if_graders_pass",
          github_owner_id: "123",
          github_repository_id: "456"
        }
      }
    }.to change(user.repositories, :count).by(1)

    expect(response).to have_http_status(:created)
    repository = user.repositories.last
    expect(repository.slug).to eq("acme/widgets")
    expect(repository.upstream_owner).to eq("rails")
    expect(repository.upstream_name).to eq("rails")
    expect(repository.upstream_default_branch).to eq("main")
    expect(repository.prepare_enabled).to eq(false)
    expect(repository.pr_cost_footer_enabled).to eq(false)
    expect(repository.auto_merge_enabled).to eq(true)
    expect(repository.agent_provider).to eq("codex")
    expect(repository.auto_approve_mode).to eq("if_graders_pass")
    expect(repository.github_owner_id).to eq(123)
    expect(repository.github_repository_id).to eq(456)
    expect(parse_body).to include("message" => "Repository acme/widgets added.", "redirect_to" => repositories_path)
  end

  it "returns validation errors when create fails" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories", params: {
        repository: {
          owner: "bad owner",
          name: "",
          default_branch: "",
          trigger_label: ""
        }
      }
    }.not_to change(user.repositories, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("Owner")
  end

  it "updates repositories" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")

    patch "/api/v1/app/repositories/#{repository.id}", params: {
      repository: {
        owner: "acme",
        name: "widgets",
        default_branch: "trunk",
        upstream_owner: "rails",
        upstream_name: "rails",
        upstream_default_branch: "main",
        trigger_label: "delegate",
        polling_enabled: "0",
        prepare_enabled: "0",
        pr_cost_footer_enabled: "0",
        auto_merge_enabled: "1",
        agent_provider: "codex",
        auto_approve_mode: "if_graders_pass_and_tagged_safe",
        github_owner_id: "123",
        github_repository_id: "456"
      }
    }

    expect(response).to have_http_status(:ok)
    expect(repository.reload.default_branch).to eq("trunk")
    expect(repository.upstream_owner).to eq("rails")
    expect(repository.upstream_name).to eq("rails")
    expect(repository.upstream_default_branch).to eq("main")
    expect(repository.trigger_label).to eq("delegate")
    expect(repository.polling_enabled).to eq(false)
    expect(repository.prepare_enabled).to eq(false)
    expect(repository.pr_cost_footer_enabled).to eq(false)
    expect(repository.auto_merge_enabled).to eq(true)
    expect(repository.agent_provider).to eq("codex")
    expect(repository.auto_approve_mode).to eq("if_graders_pass_and_tagged_safe")
    expect(repository.github_owner_id).to eq(123)
    expect(repository.github_repository_id).to eq(456)
    expect(parse_body).to include("message" => "Repository acme/widgets updated.", "redirect_to" => repositories_path)
  end

  it "enqueues a forced poll and returns the refreshed index payload" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")

    expect {
      post "/api/v1/app/repositories/#{repository.id}/poll"
    }.to have_enqueued_job(PollRepositoryJob).with(repository.id, force: true)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Polling acme/widgets now.")
    expect(parse_body.dig("active_repositories", 0, "slug")).to eq("acme/widgets")
  end

  it "enqueues a forced poll and returns the refreshed detail payload when requested" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")

    expect {
      post "/api/v1/app/repositories/#{repository.id}/poll", params: { return_to: "detail" }
    }.to have_enqueued_job(PollRepositoryJob).with(repository.id, force: true)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Polling acme/widgets now.")
    expect(parse_body.dig("repository", "slug")).to eq("acme/widgets")
    expect(parse_body).not_to have_key("active_repositories")
  end

  it "rejects polling an archived repository" do
    sign_in_as(user)
    repository = Factories.repository(user: user)
    repository.archive!

    expect {
      post "/api/v1/app/repositories/#{repository.id}/poll"
    }.not_to have_enqueued_job(PollRepositoryJob)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("archived")
  end

  it "archives and unarchives repositories" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", polling_enabled: true)

    post "/api/v1/app/repositories/#{repository.id}/archive"

    expect(response).to have_http_status(:ok)
    expect(repository.reload).to be_archived
    expect(repository.polling_enabled).to eq(false)
    expect(parse_body["message"]).to eq("acme/widgets archived.")
    expect(parse_body.dig("archived_repositories", 0, "slug")).to eq("acme/widgets")

    post "/api/v1/app/repositories/#{repository.id}/unarchive"

    expect(response).to have_http_status(:ok)
    expect(repository.reload).not_to be_archived
    expect(parse_body["message"]).to include("unarchived")
    expect(parse_body.dig("active_repositories", 0, "slug")).to eq("acme/widgets")
  end

  it "retries failed jobs through the app API" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", agent_provider: "codex")
    failed_a = Factories.job(repository: repository, issue_number: 1)
    failed_b = Factories.job(repository: repository, issue_number: 2)
    succeeded = Factories.job(repository: repository, issue_number: 3)
    failed_a.current_run.update!(state: "failed", finished_at: Time.current)
    failed_b.current_run.update!(state: "failed", finished_at: Time.current)
    succeeded.current_run.update!(state: "succeeded", finished_at: Time.current)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/retry_failed_jobs"
    }.to change { Workflow.where(trigger_kind: "retry").count }.by(2)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Retry enqueued for 2 failed jobs with Codex.")
    expect(parse_body.dig("repository", "slug")).to eq("acme/widgets")
    expect(parse_body.dig("retry_failed_jobs", "count")).to eq(0)
    expect(failed_a.reload.agent_provider).to eq("codex")
    expect(failed_b.reload.workflows.where(trigger_kind: "retry").last.agent_provider).to eq("codex")
  end

  it "rejects retrying when there are no failed jobs" do
    sign_in_as(user)
    repository = Factories.repository(user: user)
    Factories.job(repository: repository)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/retry_failed_jobs"
    }.not_to change { Workflow.where(trigger_kind: "retry").count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("No failed jobs to retry.")
  end

  it "does not expose another user's repository commands" do
    sign_in_as(user)
    foreign = Factories.repository(user: Factories.user)

    post "/api/v1/app/repositories/#{foreign.id}/archive"

    expect(response).to have_http_status(:not_found)
    expect(foreign.reload).not_to be_archived
  end

  it "does not expose another user's repository form" do
    sign_in_as(user)
    foreign = Factories.repository(user: Factories.user)

    get "/api/v1/app/repositories/#{foreign.id}/edit"

    expect(response).to have_http_status(:not_found)
  end

  it "returns GitHub owners for repository selectors" do
    sign_in_as(user)
    allow(GithubClient).to receive(:for_user).and_return(
      instance_double(GithubClient, accessible_owners: { user: "john", orgs: %w[org-a] })
    )

    get "/api/v1/app/repositories/owners"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("user" => "john", "orgs" => [ "org-a" ])
  end

  it "returns no_token for owner selectors without GitHub credentials" do
    sign_in_as(user)
    allow(GithubClient).to receive(:for_user).and_raise(ArgumentError)

    get "/api/v1/app/repositories/owners"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("error" => "no_token")
  end

  it "returns repositories for a selected owner" do
    sign_in_as(user)
    allow(GithubClient).to receive(:for_user).and_return(
      instance_double(
        GithubClient,
        owner_repos: [
          { name: "alpha", github_repository_id: 456, github_owner_id: 123 },
          { name: "beta", github_repository_id: 789, github_owner_id: 123 }
        ]
      )
    )

    get "/api/v1/app/repositories/repos", params: { owner: "john", owner_type: "user" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["repos"]).to contain_exactly(
      { "name" => "alpha", "github_repository_id" => 456, "github_owner_id" => 123 },
      { "name" => "beta", "github_repository_id" => 789, "github_owner_id" => 123 }
    )
  end

  it "returns branches for a selected repository" do
    sign_in_as(user)
    allow(GithubClient).to receive(:for_user).and_return(
      instance_double(GithubClient, repo_branches: { branches: %w[main trunk], default_branch: "main" })
    )

    get "/api/v1/app/repositories/branches", params: { owner: "john", name: "alpha" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("branches" => [ "main", "trunk" ], "default_branch" => "main")
  end
end
