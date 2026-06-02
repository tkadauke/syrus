require "rails_helper"

RSpec.describe "API: /api/v1/app/bootstrap", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  def with_env(vars)
    old_values = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  it "returns safe public bootstrap state when signed out" do
    Factories.user
    AppSetting.current.update!(signups_open: false)

    get api_v1_app_bootstrap_path

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(parse_body).to include(
      "current_user" => nil,
      "public" => include(
        "first_signup" => false,
        "signups_open" => false,
        "signup_path" => "/users/new",
        "sign_in_path" => "/session/new"
      )
    )
    expect(parse_body.dig("navigation", "default_chat_path")).to eq(new_session_path)
  end

  it "returns the signed-in user's browser bootstrap payload" do
    user = Factories.user(
      email_address: "operator@example.com",
      name: "Operator",
      scheduling_paused: true,
      landing_paused: true,
      agent_provider: "codex",
      agent_max_turns: 123
    )
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")

    body = parse_body
    expect(body["current_user"]).to include(
      "id" => user.id,
      "email_address" => "operator@example.com",
      "name" => "Operator",
      "display_name" => "Operator",
      "admin" => true,
      "scheduling_paused" => true,
      "landing_paused" => true,
      "agent_provider" => "codex",
      "agent_max_turns" => 123
    )
    expect(body["team_user_count"]).to eq(1)
    expect(body["app"]).to include(
      "revision" => "dev",
      "revision_url" => nil
    )
    expect(body["setup_status"]).to include(
      "state" => "first_admin",
      "next_step" => "configure_credentials",
      "next_step_path" => "/credentials/edit",
      "first_admin" => true,
      "credentials_configured" => false,
      "repository_configured" => false,
      "first_successful_job_completed" => false
    )
    expect(body["public"]).to include(
      "first_signup" => false,
      "signups_open" => false,
      "signup_path" => "/users/new",
      "sign_in_path" => "/session/new"
    )
    expect(body["navigation"]).to include(
      "default_chat_path" => new_chat_path
    )
    expect(body.dig("setup", "next_step")).to eq("credentials")
    expect(body.dig("setup", "paths", "setup_path")).to eq(setup_path)
    expect(body["csrf_token"]).to be_present
    expect(body["feature_flags"]).to eq("migrated_routes" => [])
  end

  it "reports credentials-only setup status without exposing write-only credential values" do
    user = Factories.user(
      github_token: "ghp_secret_pat",
      claude_oauth_token: "claude_secret_token"
    )
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    setup = parse_body.fetch("setup_status")
    expect(setup).to include(
      "state" => "credentials_only",
      "next_step" => "add_repository",
      "next_step_path" => "/repositories/new",
      "credentials_configured" => true,
      "repository_configured" => false,
      "first_successful_job_completed" => false
    )
    expect(setup.fetch("credential_status")).to eq(
      "github" => true,
      "agent" => true,
      "active_agent_provider" => "claude"
    )
    expect(setup.fetch("counts")).to include("repositories" => 0, "successful_jobs" => 0)
    expect(response.body).not_to include("ghp_secret_pat", "claude_secret_token")
    expect(setup.to_json).not_to include("github_token", "claude_oauth_token", "codex_api_key", "codex_auth_json")
  end

  it "reports repository-only setup status" do
    user = Factories.user
    Factories.repository(user: user)
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    setup = parse_body.fetch("setup_status")
    expect(setup).to include(
      "state" => "repository_only",
      "next_step" => "configure_credentials",
      "next_step_path" => "/credentials/edit",
      "credentials_configured" => false,
      "repository_configured" => true,
      "first_successful_job_completed" => false
    )
    expect(setup.fetch("counts")).to include("repositories" => 1, "successful_jobs" => 0)
  end

  it "reports first-successful-job setup status" do
    user = Factories.user(
      github_token: "ghp_secret_pat",
      claude_oauth_token: "claude_secret_token"
    )
    repository = Factories.repository(user: user)
    Factories.job_record(
      user: user,
      repository: repository,
      state: "closed",
      closure_reason: "pr_merged",
      finished_at: Time.current
    )
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    setup = parse_body.fetch("setup_status")
    expect(setup).to include(
      "state" => "first_successful_job",
      "next_step" => nil,
      "next_step_path" => nil,
      "credentials_configured" => true,
      "repository_configured" => true,
      "first_successful_job_completed" => true
    )
    expect(setup.fetch("counts")).to include("repositories" => 1, "successful_jobs" => 1)
  end

  it "uses the configured GitHub repository for non-dev revision links" do
    user = Factories.user
    sign_in_as(user)

    with_env("GIT_SHA" => "9c0f8d15", "SYRUS_GITHUB_REPO" => "operator/syrus") do
      get api_v1_app_bootstrap_path
    end

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("app", "revision_url")).to eq("https://github.com/operator/syrus/commit/9c0f8d15")
  end

  it "points the default chat navigation at the user's latest chat" do
    user = Factories.user
    old_chat = ChatSession.create!(user: user, last_message_at: 2.days.ago)
    latest_chat = ChatSession.create!(user: user, last_message_at: 1.hour.ago)
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    expect(parse_body.dig("navigation", "default_chat_path")).to eq(chat_path(latest_chat))
    expect(parse_body.dig("navigation", "default_chat_path")).not_to eq(chat_path(old_chat))
  end
end
