require "rails_helper"

RSpec.describe "API: /api/v1/app/repositories", type: :request do
  include ActiveJob::TestHelper

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
    expect(body["repositories"]).to include(
      include("slug" => "acme/widgets", "active_jobs_count" => 0),
      include("slug" => "old/repo", "archived" => true)
    )
  end

  it "adds the current user as collaborator when the same GitHub slug is already registered by another user" do
    other_user = Factories.user
    existing_repo = Factories.repository(user: other_user, owner: "acme", name: "widgets")
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
    }.to change(RepositoryMembership, :count).by(1)
      .and change(Repository, :count).by(0)

    expect(response).to have_http_status(:created)
    membership = existing_repo.repository_memberships.find_by(user: user)
    expect(membership).not_to be_nil
    expect(membership.role).to eq("collaborator")
  end

  it "creates an owner membership when registering a new repository" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories", params: {
        repository: {
          owner: "acme",
          name: "brandnew",
          default_branch: "main",
          trigger_label: "syrus",
          polling_enabled: true,
          prepare_enabled: true
        }
      }
    }.to change(Repository, :count).by(1)
      .and change(RepositoryMembership, :count).by(1)

    expect(response).to have_http_status(:created)
    repo = Repository.find_by(owner: "acme", name: "brandnew")
    expect(repo.repository_memberships.find_by(user: user).role).to eq("owner")
    expect(parse_body.dig("repository", "owner_user")).to include(
      "id" => user.id,
      "email_address" => user.email_address
    )
  end

  it "rejects a second connect attempt for the same user on the same repository" do
    sign_in_as(user)
    existing_repo = Factories.repository(user: user, owner: "acme", name: "widgets")

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
    }.not_to change(RepositoryMembership, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("already in your workspace")
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
    expect(body.dig("repository", "main_branch_health_enabled")).to eq(true)
    expect(body.dig("repository", "main_branch_repair_enabled")).to eq(true)
    expect(body.dig("repository", "main_branch_repair_auto_approve")).to eq(false)
    expect(body.dig("repository", "treat_grader_timeouts_as_failures")).to eq(false)
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
      main_branch_health_enabled: false,
      main_branch_repair_auto_approve: true,
      treat_grader_timeouts_as_failures: true,
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
      "main_branch_health_enabled" => false,
      "main_branch_repair_enabled" => false,
      "main_branch_repair_auto_approve" => true,
      "treat_grader_timeouts_as_failures" => true,
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
      github_repository_id: 200,
      ci_health: "not_configured",
      grader_health: "healthy"
    )
    repository.update!(landing_paused: true)
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
    expect(body.dig("repository", "landing_paused")).to eq(true)
    expect(body.dig("repository", "main_branch_health_enabled")).to eq(true)
    expect(body.dig("repository", "main_branch_repair_enabled")).to eq(true)
    expect(body.dig("repository", "main_branch_repair_auto_approve")).to eq(false)
    expect(body.dig("repository", "treat_grader_timeouts_as_failures")).to eq(false)
    expect(body.dig("health_history", "landing_paused")).to eq(true)
    expect(body.dig("health_history", "main_branch_health_enabled")).to eq(true)
    expect(body.dig("health_history", "main_branch_repair_enabled")).to eq(true)
    expect(body.dig("health_history", "main_branch_repair_auto_approve")).to eq(false)
    expect(body.dig("health_history", "treat_grader_timeouts_as_failures")).to eq(false)
    expect(body["tabs"]).to include(
      { "key" => "overview", "label" => "Overview", "path" => repository_path(repository) },
      { "key" => "github_issues", "label" => "GitHub Issues", "path" => repository_path(repository, tab: "github_issues") },
      { "key" => "documents", "label" => "Documents", "path" => repository_documents_path(repository) },
      { "key" => "scheduled_tasks", "label" => "Scheduled Tasks", "path" => repository_scheduled_tasks_path(repository) }
    )
    expect(body["counts"]).to include("running" => 1, "queued" => 1, "failed_7d" => 1)
    expect(body["retry_failed_jobs"]).to include("count" => 1, "agent_provider_label" => "Codex")
    expect(body.dig("retry_failed_jobs", "provider_circuit")).to include("provider" => "codex", "open" => false)
    expect(body["credential_status"]).to include(
      "mode" => "pat",
      "label" => "PAT fallback: no active App installation",
      "github_app_registered" => true,
      "install_url" => "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=100&repository_ids[]=200"
    )
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
      "app_resume_landing_repository_path" => "/api/v1/app/repositories/#{repository.id}/resume_landing",
      "app_run_main_branch_graders_repository_path" => "/api/v1/app/repositories/#{repository.id}/run_main_branch_graders",
      "app_repair_main_branch_repository_path" => "/api/v1/app/repositories/#{repository.id}/repair_main_branch",
      "app_check_ci_now_repository_path" => "/api/v1/app/repositories/#{repository.id}/check_ci_now"
    )
    expect(body["paths"].keys).not_to include("poll_repository_path", "archive_repository_path", "retry_failed_jobs_repository_path")
  end

  it "does not expose another user's repository detail" do
    sign_in_as(user)
    foreign = Factories.repository(user: Factories.user)

    get "/api/v1/app/repositories/#{foreign.id}"

    expect(response).to have_http_status(:not_found)
  end

  context "with agent_insights feature enabled" do
    let(:repository) { Factories.repository(user: user) }

    def enable_insights_feature
      Feature.find_or_create_by!(slug: "agent_insights") { |f|
        f.category = "Labs"; f.name = "Agent Insights"
      }.update!(enabled: true)
    end

    def create_insight_suggestion(repo, state: "pending")
      insight_job = Factories.job(user: user, repository: repo, kind: "agent_insight", issue_number: nil)
      InsightSuggestion.create!(
        job: insight_job,
        repository: repo,
        title: "Use caching",
        category: "performance",
        severity: "medium",
        confidence: 0.9,
        state: state
      )
    end

    it "includes the insights tab with a badge showing pending suggestion count" do
      enable_insights_feature
      sign_in_as(user)
      create_insight_suggestion(repository, state: "pending")
      create_insight_suggestion(repository, state: "pending")
      create_insight_suggestion(repository, state: "dismissed")

      get "/api/v1/app/repositories/#{repository.id}"

      expect(response).to have_http_status(:ok)
      insights_tab = parse_body["tabs"].find { |t| t["key"] == "insights" }
      expect(insights_tab).to include(
        "key" => "insights",
        "label" => "Insights",
        "path" => "/repositories/#{repository.id}/insights",
        "badge" => 2
      )
    end

    it "includes the insights tab without a badge when no pending suggestions exist" do
      enable_insights_feature
      sign_in_as(user)
      create_insight_suggestion(repository, state: "accepted")

      get "/api/v1/app/repositories/#{repository.id}"

      expect(response).to have_http_status(:ok)
      insights_tab = parse_body["tabs"].find { |t| t["key"] == "insights" }
      expect(insights_tab).to include("key" => "insights", "badge" => nil)
    end
  end

  it "includes workflow_path in health history records linked to a grader workflow" do
    sign_in_as(user)
    repository = Factories.repository(user: user)
    grader_job = Job.create!(
      user: user,
      repository: repository,
      kind: "main_grader",
      issue_title: "main_grader:abc",
      issue_number: nil
    )
    workflow = Workflows::MainGrader.instantiate(job: grader_job, artifacts: { "main_sha" => "abc123" })
    check_with = MainBranchHealthCheck.record_grader_workflow(
      repository: repository, sha: "abc123", grader_health: "healthy", workflow: workflow
    )
    check_without = MainBranchHealthCheck.record_ci_poll(
      repository: repository, sha: "def456", ci_health: "healthy"
    )

    get "/api/v1/app/repositories/#{repository.id}"

    expect(response).to have_http_status(:ok)
    records = parse_body.dig("health_history", "records")
    linked = records.find { |r| r["id"] == check_with.id }
    unlinked = records.find { |r| r["id"] == check_without.id }
    expect(linked["workflow_path"]).to eq("/jobs/#{grader_job.id}?tab=workflows#workflow-#{workflow.id}")
    expect(unlinked["workflow_path"]).to be_nil
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
          main_branch_repair_auto_approve: "1",
          treat_grader_timeouts_as_failures: "1",
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
    expect(repository.main_branch_health_enabled).to eq(true)
    expect(repository.main_branch_repair_enabled).to eq(false)
    expect(repository.main_branch_repair_auto_approve).to eq(true)
    expect(repository.treat_grader_timeouts_as_failures).to eq(true)
    expect(repository.agent_provider).to eq("codex")
    expect(repository.auto_approve_mode).to eq("if_graders_pass")
    expect(repository.github_owner_id).to eq(123)
    expect(repository.github_repository_id).to eq(456)
    expect(parse_body).to include("message" => "Repository acme/widgets added.", "redirect_to" => repositories_path)
  end

  it "honors explicit main branch repair settings when creating fork repositories" do
    sign_in_as(user)

    post "/api/v1/app/repositories", params: {
      repository: {
        owner: "acme",
        name: "widgets",
        default_branch: "main",
        upstream_owner: "rails",
        upstream_name: "rails",
        upstream_default_branch: "main",
        trigger_label: "syrus",
        main_branch_health_enabled: "1",
        main_branch_repair_enabled: "1",
        main_branch_repair_auto_approve: "1"
      }
    }

    expect(response).to have_http_status(:created)
    repository = user.repositories.last
    expect(repository.main_branch_health_enabled).to eq(true)
    expect(repository.main_branch_repair_enabled).to eq(true)
    expect(repository.main_branch_repair_auto_approve).to eq(true)
  end

  it "includes the credential status (with a pre-scoped install link) in the create response" do
    sign_in_as(user)
    AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")

    post "/api/v1/app/repositories", params: {
      repository: {
        owner: "acme", name: "widgets", default_branch: "main", trigger_label: "syrus",
        github_owner_id: "123", github_repository_id: "456"
      }
    }

    expect(response).to have_http_status(:created)
    # The add-repository flow offers the App install exactly here, where the
    # repo just became known — so the payload must carry mode + install_url.
    expect(parse_body["credential_status"]).to include(
      "mode" => "pat",
      "github_app_registered" => true,
      "install_url" => "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=123&repository_ids[]=456",
      # Account-level page for the all-repositories re-offer.
      "generic_install_url" => "https://github.com/apps/operator-syrus/installations/new"
    )
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
        main_branch_health_enabled: "0",
        main_branch_repair_enabled: "0",
        main_branch_repair_auto_approve: "1",
        treat_grader_timeouts_as_failures: "1",
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
    expect(repository.main_branch_health_enabled).to eq(false)
    expect(repository.main_branch_repair_enabled).to eq(false)
    expect(repository.main_branch_repair_auto_approve).to eq(true)
    expect(repository.treat_grader_timeouts_as_failures).to eq(true)
    expect(repository.agent_provider).to eq("codex")
    expect(repository.auto_approve_mode).to eq("if_graders_pass_and_tagged_safe")
    expect(repository.github_owner_id).to eq(123)
    expect(repository.github_repository_id).to eq(456)
    expect(parse_body).to include("message" => "Repository acme/widgets updated.", "redirect_to" => repositories_path)
  end

  it "resumes repository work even when main remains broken" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", landing_paused: true, ci_health: "broken")

    expect {
      post "/api/v1/app/repositories/#{repository.id}/resume_landing", params: { page: 1 }
    }.to have_enqueued_job(LandingQueueProcessorJob)

    expect(response).to have_http_status(:ok)
    expect(repository.reload.landing_paused).to eq(false)
    expect(parse_body.dig("repository", "landing_paused")).to eq(false)
    expect(parse_body.dig("repository", "main_health")).to eq("broken")
    expect(parse_body["message"]).to eq("Work resumed for acme/widgets.")
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

  it "lists and releases needs-triage jobs for developers" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    job = user.jobs.create!(
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Scope the importer",
      issue_body: "Make this ready for implementation.",
      state: "needs_triage"
    )

    get "/api/v1/app/repositories/#{repository.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["can_release_triage_jobs"]).to eq(true)
    expect(parse_body["needs_triage_jobs"]).to contain_exactly(include("id" => job.id, "issue_title" => "Scope the importer"))

    expect {
      post "/api/v1/app/repositories/#{repository.id}/release_needs_triage_job", params: { job_id: job.id }
    }.to have_enqueued_job(RunJob)

    expect(response).to have_http_status(:ok)
    expect(job.reload).to be_queued
    expect(parse_body["message"]).to eq("Released #{job.slug} for triage.")
    transition = StateTransition.for_subject(job).find_by!(event_name: "release_for_triage")
    expect(transition).to have_attributes(
      from_state: "needs_triage",
      to_state: "triaging",
      event_name: "release_for_triage",
      source: "operator",
      user_id: user.id
    )
  end

  it "hides and rejects needs-triage release for product owners" do
    user.update!(role: "product_owner", admin: false)
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    job = user.jobs.create!(
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Scope the importer",
      issue_body: "Make this ready for implementation.",
      state: "needs_triage"
    )

    get "/api/v1/app/repositories/#{repository.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["can_release_triage_jobs"]).to eq(false)
    expect(parse_body["needs_triage_jobs"]).to eq([])

    post "/api/v1/app/repositories/#{repository.id}/release_needs_triage_job", params: { job_id: job.id }

    expect(response).to have_http_status(:forbidden)
    expect(job.reload).to be_needs_triage
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

  it "rejects repository-wide retries while the provider circuit is open" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", agent_provider: "codex")
    failed = Factories.job(repository: repository, issue_number: 1, agent_provider: "codex")
    failed.current_run.update!(state: "failed", finished_at: Time.current)
    5.times do |index|
      job = Factories.job(repository: repository, issue_number: index + 100, agent_provider: "codex")
      Run.create!(
        job: job,
        step: job.latest_workflow.first_step,
        trigger_kind: "initial",
        state: "failed",
        agent_provider: "codex",
        agent_outcome: "provider_transient",
        finished_at: 1.minute.ago
      )
    end

    expect {
      post "/api/v1/app/repositories/#{repository.id}/retry_failed_jobs"
    }.not_to change { Workflow.where(trigger_kind: "retry").count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("Codex appears degraded")
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

  it "includes feedback_policy in the edit form payload" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", feedback_policy: "auto")

    get "/api/v1/app/repositories/#{repository.id}/edit"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("repository", "feedback_policy")).to eq("auto")
  end

  it "updates feedback_policy via PATCH" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", feedback_policy: "auto")

    patch "/api/v1/app/repositories/#{repository.id}", params: {
      repository: {
        owner: repository.owner,
        name: repository.name,
        default_branch: repository.default_branch,
        trigger_label: repository.trigger_label,
        feedback_policy: "confirm"
      }
    }

    expect(response).to have_http_status(:ok)
    expect(repository.reload.feedback_policy).to eq("confirm")
  end

  it "enqueues main branch graders for the tracked SHA" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", last_health_checked_sha: "abc1234def5678")

    expect {
      post "/api/v1/app/repositories/#{repository.id}/run_main_branch_graders", params: { return_to: "detail", page: 1 }
    }.to have_enqueued_job(MainGraderWorkflowJob).with(repository.id, "abc1234def5678")

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Graders enqueued for abc1234 on acme/widgets.")
    expect(parse_body.dig("repository", "slug")).to eq("acme/widgets")
  end

  it "rejects run_main_branch_graders for an archived repository" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", last_health_checked_sha: "abc1234")
    repository.archive!

    post "/api/v1/app/repositories/#{repository.id}/run_main_branch_graders"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("archived")
  end

  it "rejects run_main_branch_graders when no SHA has been tracked yet" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    repository.update_columns(last_health_checked_sha: nil)

    post "/api/v1/app/repositories/#{repository.id}/run_main_branch_graders"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("No branch SHA tracked")
  end

  it "includes run_main_branch_graders path in the detail payload" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")

    get "/api/v1/app/repositories/#{repository.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("paths", "app_run_main_branch_graders_repository_path")).to eq(
      "/api/v1/app/repositories/#{repository.id}/run_main_branch_graders"
    )
  end

  it "creates a main branch repair job on operator request before health signals settle" do
    sign_in_as(user)
    repository = Factories.repository(
      user: user,
      owner: "acme",
      name: "widgets",
      last_health_checked_sha: "abc1234def5678",
      last_ci_evaluated_sha: "abc1234def5678",
      ci_health: "broken",
      grader_health: "unknown"
    )
    MainBranchHealthCheck.record_ci_poll(
      repository: repository,
      sha: "abc1234def5678",
      ci_health: "broken",
      ci_failed_checks: [
        { name: "RSpec", url: "https://github.com/acme/widgets/actions/runs/42" }
      ]
    )

    expect {
      post "/api/v1/app/repositories/#{repository.id}/repair_main_branch", params: { return_to: "detail", page: 1 }
    }.to change { repository.jobs.where(system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR).count }.by(1)

    expect(response).to have_http_status(:ok)
    fix_job = repository.jobs.where(system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR).last
    expect(parse_body["message"]).to eq("Repair job #{fix_job.slug} started.")
    expect(parse_body.dig("health_history", "main_branch_repair")).to include(
      "blocked_reason" => "active",
      "blocking_job" => include("slug" => fix_job.slug, "job_path" => job_path(fix_job))
    )
  end

  it "returns the existing repair job when operator repair is already blocked" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets", ci_health: "broken", grader_health: "healthy")
    repair_job = repository.jobs.create!(
      user: user,
      kind: "direct",
      system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
      issue_title: "repair in flight",
      issue_body: "fixing main",
      agent_provider: "claude",
      priority: "high",
      state: "running"
    )

    expect {
      post "/api/v1/app/repositories/#{repository.id}/repair_main_branch", params: { return_to: "detail", page: 1 }
    }.not_to change { repository.jobs.count }

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Repair job #{repair_job.slug} is already active.")
  end

  it "enqueues a CI check poll for check_ci_now" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    repository.update_columns(ci_health: "healthy")

    expect {
      post "/api/v1/app/repositories/#{repository.id}/check_ci_now", params: { return_to: "detail", page: 1 }
    }.to have_enqueued_job(PollMainBranchHealthJob).with(repository.id)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("CI check enqueued for acme/widgets.")
    expect(parse_body.dig("repository", "slug")).to eq("acme/widgets")
  end

  it "rejects check_ci_now for an archived repository" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    repository.archive!

    post "/api/v1/app/repositories/#{repository.id}/check_ci_now"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("archived")
  end

  it "rejects check_ci_now when CI is not configured" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")
    repository.update_columns(ci_health: "not_configured")

    post "/api/v1/app/repositories/#{repository.id}/check_ci_now"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("No CI checks found")
  end

  it "includes check_ci_now path in the detail payload" do
    sign_in_as(user)
    repository = Factories.repository(user: user, owner: "acme", name: "widgets")

    get "/api/v1/app/repositories/#{repository.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("paths", "app_check_ci_now_repository_path")).to eq(
      "/api/v1/app/repositories/#{repository.id}/check_ci_now"
    )
  end

  describe "GET /api/v1/app/repositories/:id/coverage_trend" do
    let(:repository) { Factories.repository(user: user, default_branch: "main") }

    def create_snapshot(branch: "main", lines_pct: 80.0, branches_pct: 60.0, functions_pct: 90.0, created_at: Time.current)
      job = Factories.job(repository: repository)
      workflow = job.workflows.first
      snap = CoverageSnapshot.create!(
        repository: repository,
        workflow: workflow,
        sha: SecureRandom.hex(10),
        branch: branch,
        lines_pct: lines_pct,
        branches_pct: branches_pct,
        functions_pct: functions_pct
      )
      snap.update_columns(created_at: created_at)
      snap
    end

    it "returns 200 with correct shape when snapshots exist" do
      sign_in_as(user)
      snap = create_snapshot(created_at: 1.day.ago)

      get "/api/v1/app/repositories/#{repository.id}/coverage_trend"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["days"]).to eq(30)
      expect(body["trend"]).to be_an(Array)
      expect(body["trend"].first).to include("date", "lines_pct", "branches_pct")
      expect(body["latest"]).to include(
        "lines_pct" => snap.lines_pct.to_f,
        "branches_pct" => snap.branches_pct.to_f,
        "functions_pct" => snap.functions_pct.to_f
      )
    end

    it "returns empty trend array when no snapshots exist" do
      sign_in_as(user)

      get "/api/v1/app/repositories/#{repository.id}/coverage_trend"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["days"]).to eq(30)
      expect(body["trend"]).to eq([])
      expect(body["latest"]).to be_nil
    end

    it "respects the days param" do
      sign_in_as(user)
      old_snap = create_snapshot(created_at: 40.days.ago)
      new_snap = create_snapshot(created_at: 5.days.ago)

      get "/api/v1/app/repositories/#{repository.id}/coverage_trend", params: { days: 10 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["days"]).to eq(10)
      trend_dates = body["trend"].map { |row| row["date"] }
      expect(trend_dates).not_to include(old_snap.created_at.to_date.to_s)
    end

    it "returns 401 when not signed in" do
      get "/api/v1/app/repositories/#{repository.id}/coverage_trend"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for another user's repository" do
      sign_in_as(user)
      foreign = Factories.repository(user: Factories.user)

      get "/api/v1/app/repositories/#{foreign.id}/coverage_trend"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST sync_fork" do
    it "enqueues a SyncForkJob for a fork with an in-instance upstream" do
      sign_in_as(user)
      upstream = Factories.repository(user: user, owner: "upstream-org", name: "project")
      fork_repo = Factories.repository(user: user, owner: "fork-user", name: "project", upstream_repository: upstream)

      expect {
        post "/api/v1/app/repositories/#{fork_repo.id}/sync_fork"
      }.to have_enqueued_job(SyncForkJob).with(fork_repo.id)

      expect(response).to have_http_status(:ok)
    end

    it "422s for a repository without an in-instance upstream" do
      sign_in_as(user)
      plain = Factories.repository(user: user, owner: "solo", name: "app")

      post "/api/v1/app/repositories/#{plain.id}/sync_fork"

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end

    it "updates fork_auto_sync_enabled through the update endpoint" do
      sign_in_as(user)
      upstream = Factories.repository(user: user, owner: "upstream-org", name: "project")
      fork_repo = Factories.repository(user: user, owner: "fork-user", name: "project", upstream_repository: upstream)

      patch "/api/v1/app/repositories/#{fork_repo.id}", params: { repository: { fork_auto_sync_enabled: true } }

      expect(response).to have_http_status(:ok)
      expect(fork_repo.reload.fork_auto_sync_enabled).to be(true)
    end
  end
end
