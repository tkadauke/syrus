require "rails_helper"

RSpec.describe "API: /api/v1/app/setup", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "returns a JSON 401 when signed out" do
    get "/api/v1/app/setup"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "returns computed setup status for a partially configured user" do
    user = Factories.user(github_token: "ghp_test")
    sign_in_as(user)

    get "/api/v1/app/setup"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "complete" => false,
      "next_step" => "credentials"
    )
    expect(body.dig("credentials", "github_token")).to eq(true)
    expect(body.dig("system", "ready")).to eq(true)
    expect(body.dig("credentials", "selected_agent_provider_configured")).to eq(false)
    expect(body.dig("github_app", "explanation")).to include("falls back to your GitHub PAT")
    expect(body.dig("paths", "setup_path")).to eq(setup_path)
  end

  it "reports the full first-run setup sequence through the setup endpoint" do
    user = Factories.user(github_token: "ghp_test", claude_oauth_token: "oat-test")
    sign_in_as(user)

    get "/api/v1/app/setup"

    credentials_ready = parse_body
    expect(credentials_ready).to include(
      "complete" => false,
      "next_step" => "repository"
    )
    expect(credentials_ready.dig("credentials", "ready")).to eq(true)
    expect(credentials_ready.dig("progress", "completed")).to eq(1)
    expect(credentials_ready.dig("repositories", "active_count")).to eq(0)
    expect(credentials_ready.dig("first_job", "any")).to eq(false)

    repository = Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus")

    get "/api/v1/app/setup"

    repository_ready = parse_body
    expect(repository_ready).to include(
      "complete" => false,
      "next_step" => "first_job"
    )
    expect(repository_ready.dig("progress", "completed")).to eq(2)
    expect(repository_ready.dig("repositories", "first")).to include(
      "slug" => "acme/widgets",
      "trigger_label" => "syrus",
      "credential_mode" => "pat",
      "repository_path" => repository_path(repository),
      "issues_path" => repository_path(repository, tab: "github_issues")
    )
    expect(repository_ready.dig("first_job", "any")).to eq(false)

    job = Factories.job_record(
      user: user,
      repository: repository,
      issue_title: "Inspect the aqueduct",
      state: "running"
    )

    get "/api/v1/app/setup"

    first_job_started = parse_body
    expect(first_job_started).to include(
      "complete" => false,
      "next_step" => "watch_job"
    )
    expect(first_job_started.dig("progress", "completed")).to eq(3)
    expect(first_job_started.dig("first_job", "any")).to eq(true)
    expect(first_job_started.dig("first_job", "successful")).to eq(false)
    expect(first_job_started.dig("first_job", "job")).to include(
      "id" => job.id,
      "title" => "Inspect the aqueduct",
      "state" => "running",
      "repository_slug" => "acme/widgets",
      "job_path" => job_path(job)
    )

    job.update!(state: "closed", closure_reason: "no_changes", finished_at: Time.current)

    get "/api/v1/app/setup"

    complete = parse_body
    expect(complete).to include(
      "complete" => true,
      "next_step" => "complete"
    )
    expect(complete.dig("progress", "completed")).to eq(4)
    expect(complete.dig("first_job", "successful")).to eq(true)
    expect(complete.dig("first_job", "job")).to include(
      "state" => "closed",
      "closure_reason" => "no_changes"
    )
  end

  it "includes readiness and navigation-safe paths in the setup payload" do
    user = Factories.user
    AppSetting.current.update!(polling_paused: true, runs_paused: true)
    sign_in_as(user)

    get "/api/v1/app/setup"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("system", "ready")).to eq(false)
    expect(body.dig("system", "polling_paused")).to eq(true)
    expect(body.dig("system", "runs_paused")).to eq(true)
    expect(body.fetch("paths")).to include(
      "setup_path" => setup_path,
      "credentials_path" => edit_credentials_path,
      "new_repository_path" => new_repository_path,
      "repositories_path" => repositories_path,
      "new_job_path" => new_job_path,
      "dashboard_jobs_path" => dashboard_jobs_path
    )
  end
end
