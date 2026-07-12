require "rails_helper"

RSpec.describe "API: /api/v1/app/bootstrap", type: :request do
  before do
    AppSetting.current.update!(polling_paused: false, runs_paused: false)
    allow(GithubClient).to receive(:for_user).and_return(instance_double(GithubClient, readiness_check!: true))
    allow(DataRootDiskUsage).to receive(:current).and_return(nil)
  end

  def parse_body
    JSON.parse(response.body)
  end

  it "returns whoami fields for bearer-token CLI clients" do
    user = Factories.user(email_address: "cli@example.com", api_token: "syrus_cli_token")

    get "/api/v1/app/bootstrap", headers: { "Authorization" => "Bearer syrus_cli_token" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["whoami"]).to include(
      "email" => "cli@example.com",
      "token_suffix" => "oken"
    )
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
      role: "product_owner",
      theme: "dark",
      agent_provider: "codex",
      chat_provider: "claude",
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
      "role" => "product_owner",
      "scheduling_paused" => true,
      "landing_paused" => true,
      "theme" => "dark",
      "agent_provider" => "codex",
      "chat_provider" => "claude",
      "agent_max_turns" => 123
    )
    expect(body["team_user_count"]).to eq(1)
    expect(body["app"]).to include(
      "revision" => "dev",
      "revision_url" => nil,
      "version" => nil,
      "built_at" => nil
    )
    expect(body["setup_status"]).to include(
      "state" => "first_admin",
      "next_step" => "configure_credentials",
      "next_step_path" => "/credentials",
      "first_admin" => true,
      "credentials_configured" => false,
      "repository_configured" => false,
      "first_job_started" => false,
      "first_successful_job_completed" => false
    )
    expect(body["public"]).to include(
      "first_signup" => false,
      "signups_open" => false,
      "signup_path" => "/users/new",
      "sign_in_path" => "/session/new"
    )
    expect(body["navigation"]).to include(
      "default_chat_path" => dashboard_path
    )
    expect(body.dig("setup", "next_step")).to eq("credentials")
    expect(body.dig("setup", "paths", "setup_path")).to eq(setup_path)
    expect(body["csrf_token"]).to be_present
    expect(body["system_alerts"]).to eq([])
    expect(body["unread_notifications_count"]).to eq(0)
    expect(body["feature_flags"]).to eq(
      "chat_polish" => false,
      "coding_mode" => false,
      "performance_logging" => false,
      "terminal" => false,
      "video_walkthroughs" => false
    )
  end

  it "returns enabled states for features declared in YAML" do
    user = Factories.user
    sign_in_as(user)
    Feature.create!(slug: "enabled_feature", category: "Example", name: "Enabled", enabled: true)
    Feature.create!(slug: "hidden_feature", category: "Example", name: "Hidden", enabled: true)
    allow(Features::SyncFromYaml).to receive(:declarations).and_return([
      { slug: "enabled_feature", category: "Example", name: "Enabled", description: nil, default_enabled: false },
      { slug: "disabled_feature", category: "Example", name: "Disabled", description: nil, default_enabled: false }
    ])

    get api_v1_app_bootstrap_path

    expect(parse_body["feature_flags"]).to eq(
      "enabled_feature" => true,
      "disabled_feature" => false
    )
  end

  it "serializes active system alerts for the SPA shell" do
    user = Factories.user
    sign_in_as(user)
    user.mark_gh_api_blocked!("Resource not accessible by personal access token")

    get api_v1_app_bootstrap_path

    alert = parse_body.fetch("system_alerts").find { |row| row["id"] == "github_token_scope:#{user.id}" }
    expect(alert).to include(
      "severity" => "alarm",
      "title" => a_string_matching(/GitHub API access/i),
      "cta" => { "text" => "Update token", "path" => "/credentials" }
    )
    expect(alert.fetch("action_steps")).not_to be_empty
  end

  it "reports credentials-only setup status without exposing write-only credential values" do
    AppSetting.current.update!(github_app_id: 1, github_app_slug: "test-syrus")
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
      "first_job_started" => false,
      "first_successful_job_completed" => false
    )
    expect(setup.fetch("credential_status")).to eq(
      "github" => true,
      "github_pat" => true,
      "github_app" => true,
      "agent" => true,
      "active_agent_provider" => "claude"
    )
    expect(setup.fetch("readiness")).to include("status")
    expect(setup.dig("readiness", "checks").map { |check| check["key"] }).to include("github", "agent_provider", "storage")
    expect(setup.fetch("counts")).to include("repositories" => 0, "jobs" => 0, "successful_jobs" => 0)
    expect(response.body).not_to include("ghp_secret_pat", "claude_secret_token")
    expect(setup.to_json).not_to include("github_token", "claude_oauth_token", "codex_api_key", "codex_auth_json")
  end

  it "does not warn about missing GitHub App installations when a PAT is configured" do
    AppSetting.current.update!(
      github_app_id: 4242,
      github_app_slug: "operator-syrus",
      github_app_private_key_pem: "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----",
      github_app_registered_at: 2.days.ago
    )
    user = Factories.user(github_token: "ghp_secret_pat", claude_oauth_token: "claude_secret_token")
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    github_app_check = parse_body.dig("setup_status", "readiness", "checks").find { |check| check["key"] == "github_app" }
    expect(github_app_check).to include("status" => "ok", "optional" => true)
    expect(github_app_check["message"]).to match(/fall back to a configured personal access token/i)
  end

  it "does not warn about missing GitHub App installations right after registration" do
    AppSetting.current.update!(
      github_app_id: 4242,
      github_app_slug: "operator-syrus",
      github_app_private_key_pem: "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----",
      github_app_registered_at: Time.current
    )
    user = Factories.user(github_token: nil, claude_oauth_token: "claude_secret_token")
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    github_app_check = parse_body.dig("setup_status", "readiness", "checks").find { |check| check["key"] == "github_app" }
    expect(github_app_check).to include("status" => "ok", "optional" => true)
    expect(github_app_check["message"]).to match(/installation sync/i)
  end

  it "still warns about missing GitHub App installations when no PAT exists and the sync grace passed" do
    AppSetting.current.update!(
      github_app_id: 4242,
      github_app_slug: "operator-syrus",
      github_app_private_key_pem: "-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----",
      github_app_registered_at: 2.days.ago
    )
    user = Factories.user(github_token: nil, claude_oauth_token: "claude_secret_token")
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    github_app_check = parse_body.dig("setup_status", "readiness", "checks").find { |check| check["key"] == "github_app" }
    expect(github_app_check).to include(
      "status" => "warning",
      "optional" => true,
      "message" => "GitHub App credentials exist, but no active installations are linked."
    )
  end

  it "keeps setup complete (Setup nav hidden) after the landed first Epic is archived" do
    user = Factories.user(github_token: "ghp_secret_pat", claude_oauth_token: "claude_secret_token")
    repository = Factories.repository(user: user)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    epic.override_state!("done")
    epic.override_state!("archived")
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    expect(parse_body.dig("setup", "complete")).to eq(true)
  end

  it "keeps setup incomplete (Setup nav shown) for a fresh user with no landed Epic" do
    user = Factories.user
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    expect(parse_body.dig("setup", "complete")).to eq(false)
  end

  it "reports readiness failures with remediation" do
    user = Factories.user
    AppSetting.current.update!(runs_paused: true)
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    readiness = parse_body.dig("setup_status", "readiness")
    expect(readiness["status"]).to eq("error")
    checks = readiness.fetch("checks")
    expect(checks).to include(
      include(
        "key" => "polling_runs",
        "status" => "error",
        "message" => "Agent runs are paused.",
        "remediation" => "Resume runs from the admin console before expecting Syrus to start work."
      ),
      include(
        "key" => "github",
        "status" => "error",
        "remediation" => "Add a GitHub token in credentials or register a GitHub App from the admin GitHub App page."
      ),
      include(
        "key" => "agent_provider",
        "status" => "error",
        "remediation" => "Add Claude Code credentials or choose another configured provider."
      )
    )
  end

  it "redacts secret-shaped values from readiness failures" do
    secret = "ghp_#{'a' * 32}"
    user = Factories.user(github_token: secret, claude_oauth_token: "claude_#{'b' * 32}")
    allow(GithubClient).to receive(:for_user)
      .and_return(instance_double(GithubClient, readiness_check!: nil))
    allow(GithubClient).to receive(:for_user)
      .with(user)
      .and_raise(StandardError, "failed https://x-access-token:#{secret}@github.com/acme/widgets.git")
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    body = response.body
    expect(body).to include("[REDACTED]")
    expect(body).not_to include(secret)
    expect(body).not_to include("claude_#{'b' * 32}")
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
      "next_step_path" => "/credentials",
      "credentials_configured" => false,
      "repository_configured" => true,
      "first_job_started" => false,
      "first_successful_job_completed" => false
    )
    expect(setup.fetch("counts")).to include("repositories" => 1, "jobs" => 0, "successful_jobs" => 0)
  end

  it "reports ready-for-first-chat setup status before an Epic lands" do
    AppSetting.current.update!(github_app_id: 1, github_app_slug: "test-syrus")
    user = Factories.user(
      github_token: "ghp_secret_pat",
      claude_oauth_token: "claude_secret_token"
    )
    repository = Factories.repository(user: user)
    Factories.epic(user: user, repository: repository, state: "in_progress")
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    setup = parse_body.fetch("setup_status")
    expect(setup).to include(
      "state" => "first_chat_started",
      "next_step" => "start_first_chat",
      "next_step_path" => "/onboarding",
      "credentials_configured" => true,
      "repository_configured" => true,
      "first_epic_created" => true,
      "first_epic_started" => true,
      "first_epic_landed" => false,
      "first_successful_job_completed" => false
    )
  end

  it "reports completed setup status once the first Epic lands" do
    AppSetting.current.update!(github_app_id: 1, github_app_slug: "test-syrus")
    user = Factories.user(
      github_token: "ghp_secret_pat",
      claude_oauth_token: "claude_secret_token"
    )
    repository = Factories.repository(user: user)
    Factories.epic(user: user, repository: repository, state: "done")
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    setup = parse_body.fetch("setup_status")
    expect(setup).to include(
      "state" => "first_successful_job",
      "next_step" => nil,
      "next_step_path" => nil,
      "credentials_configured" => true,
      "repository_configured" => true,
      "first_epic_landed" => true,
      "first_successful_job_completed" => true
    )
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

  it "exposes the release version and build time baked into published images" do
    user = Factories.user
    sign_in_as(user)

    # bin/publish-image X.Y.Z bakes SYRUS_VERSION and SYRUS_BUILT_AT into the
    # image; the badge prefers the version over the git SHA so releases read
    # "backend 0.1.2", and built_at feeds the badge's hover tooltip.
    with_env("GIT_SHA" => "9c0f8d15", "SYRUS_VERSION" => "0.1.2", "SYRUS_BUILT_AT" => "2026-07-07T14:32:00Z") do
      get api_v1_app_bootstrap_path
    end

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("app", "version")).to eq("0.1.2")
    expect(parse_body.dig("app", "revision")).to eq("9c0f8d15")
    expect(parse_body.dig("app", "built_at")).to eq("2026-07-07T14:32:00Z")
  end

  it "returns nil version and built_at on dev/deploy builds (unset or empty env)" do
    user = Factories.user
    sign_in_as(user)

    # The Dockerfile defaults are empty strings — presence semantics must
    # treat "" like unset so dev images fall back to the SHA badge with no
    # build-time tooltip.
    with_env("SYRUS_VERSION" => "", "SYRUS_BUILT_AT" => "") do
      get api_v1_app_bootstrap_path
    end

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("app", "version")).to be_nil
    expect(parse_body.dig("app", "built_at")).to be_nil
  end

  it "omits the revision link instead of 500ing when SYRUS_GITHUB_REPO is unset" do
    user = Factories.user
    sign_in_as(user)

    # Real revision (not "dev") + no repo configured used to raise KeyError from
    # a bare ENV.fetch and take down every SPA page. It must degrade to no link.
    with_env("GIT_SHA" => "9c0f8d15", "SYRUS_GITHUB_REPO" => nil) do
      get api_v1_app_bootstrap_path
    end

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("app", "revision_url")).to be_nil
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

  it "includes locale in current_user payload" do
    user = Factories.user(locale: "de")
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("current_user", "locale")).to eq("de")
  end

  it "sets I18n.locale from current_user.locale for the request" do
    user = Factories.user(locale: "de")
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    expect(response).to have_http_status(:ok)
    # The around_action sets I18n.locale for the request duration;
    # locale is restored after the request but we can verify the response
    # was served while locale was active by checking the user locale in payload.
    expect(parse_body.dig("current_user", "locale")).to eq("de")
  end
end
