require "rails_helper"

RSpec.describe AppApi::SetupStatus do
  let(:readiness_payload) { { status: "ok", checks: [] } }

  before do
    allow(AppApi::ReadinessChecks).to receive(:new)
      .and_return(instance_double(AppApi::ReadinessChecks, as_json: readiness_payload))
    allow(App::Presentation).to receive(:agent_provider_label).with("claude").and_return("Claude")
  end

  def setup_status_for(user)
    described_class.new(user).as_json
  end

  def register_github_app
    AppSetting.current.update!(github_app_id: 123, github_app_slug: "test-syrus")
  end

  it "reports a first admin before credentials or repositories are configured" do
    user = Factories.user

    expect(setup_status_for(user)).to include(
      state: "first_admin",
      next_step: "configure_credentials",
      next_step_path: "/credentials",
      first_admin: true,
      credentials_configured: false,
      repository_configured: false,
      first_successful_job_completed: false,
      readiness: readiness_payload,
      counts: { repositories: 0, jobs: 0, successful_jobs: 0 }
    )
  end

  it "requires both agent credentials and GitHub App credentials before credentials are complete" do
    Factories.user
    user = Factories.user(github_token: "ghp_secret_pat", claude_oauth_token: "oat-secret")

    expect(setup_status_for(user)).to include(
      state: "not_started",
      next_step: "configure_credentials",
      credentials_configured: false,
      credential_status: include(
        github: false,
        github_pat: true,
        github_app: false,
        agent: true,
        active_agent_provider: "claude",
        active_agent_provider_label: "Claude"
      )
    )
  end

  it "moves from credentials-only to ready-for-first-chat once an active repository exists" do
    register_github_app
    user = Factories.user(github_token: "ghp_secret_pat", claude_oauth_token: "oat-secret")

    expect(setup_status_for(user)).to include(
      state: "credentials_only",
      next_step: "add_repository",
      next_step_path: "/repositories/new",
      credentials_configured: true,
      repository_configured: false
    )

    Factories.repository(user: user)

    expect(setup_status_for(user)).to include(
      state: "ready_for_first_chat",
      next_step: "start_first_chat",
      next_step_path: "/onboarding",
      credentials_configured: true,
      repository_configured: true,
      counts: include(repositories: 1)
    )
  end

  it "uses Epic progress for the final onboarding states" do
    register_github_app
    user = Factories.user(github_token: "ghp_secret_pat", claude_oauth_token: "oat-secret")
    repository = Factories.repository(user: user)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")

    expect(setup_status_for(user)).to include(
      state: "first_chat_started",
      next_step: "start_first_chat",
      first_epic_created: true,
      first_epic_started: true,
      first_epic_landed: false,
      first_successful_job_completed: false
    )

    epic.update!(state: "done", done_at: Time.current)

    expect(setup_status_for(user)).to include(
      state: "first_successful_job",
      next_step: nil,
      next_step_path: nil,
      first_epic_landed: true,
      first_successful_job_completed: true
    )
  end

  it "counts active repositories and successful jobs separately from all jobs" do
    register_github_app
    user = Factories.user(github_token: "ghp_secret_pat", claude_oauth_token: "oat-secret")
    active_repository = Factories.repository(user: user)
    Factories.repository(user: user, archived_at: 1.day.ago)
    Factories.job_record(user: user, repository: active_repository, state: "queued")
    Factories.job_record(
      user: user,
      repository: active_repository,
      state: "closed",
      closure_reason: Job::SUCCESSFUL_CLOSURE_REASONS.first
    )

    expect(setup_status_for(user)).to include(
      repository_configured: true,
      first_job_started: true,
      counts: {
        repositories: 1,
        jobs: 2,
        successful_jobs: 1
      }
    )
  end
end
