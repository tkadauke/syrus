require "rails_helper"

RSpec.describe "API: /api/v1/app/profiles", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/profiles"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "lists team profiles without exposing credentials" do
    viewer = Factories.user
    unprofiled = Factories.user(email_address: "private@example.com")
    teammate = Factories.user(
      email_address: "teammate@example.com",
      first_name: "Ada",
      last_name: "Lovelace",
      github_handle: "@ada",
      profile_bio: "Works on the analytical engine.",
      avatar_url: "https://example.com/ada.png",
      github_token: "ghp_secret",
      claude_oauth_token: "sk-secret"
    )
    repo = Factories.repository(user: teammate, owner: "acme", name: "engine")
    Factories.epic(user: teammate, repository: repo, title: "Profiles")
    Factories.job_record(user: teammate, repository: repo, issue_title: "Ship profile pages")
    sign_in_as(viewer)

    get "/api/v1/app/profiles"

    expect(response).to have_http_status(:ok)
    body = parse_body
    row = body["profiles"].find { |profile| profile["id"] == teammate.id }
    unprofiled_row = body["profiles"].find { |profile| profile["id"] == unprofiled.id }
    expect(row).to include(
      "display_name" => "Ada Lovelace",
      "github_handle" => "ada",
      "role_label" => "Operator",
      "avatar_url" => "https://example.com/ada.png",
      "profile_path" => "/profiles/#{teammate.id}"
    )
    expect(row.dig("counts", "repositories")).to eq(1)
    expect(row.dig("counts", "epics")).to eq(1)
    expect(row.dig("counts", "jobs")).to eq(1)
    expect(unprofiled_row["display_name"]).to eq("User ##{unprofiled.id}")
    expect(response.body).not_to include("ghp_secret")
    expect(response.body).not_to include("sk-secret")
    expect(response.body).not_to include("teammate@example.com")
    expect(response.body).not_to include("private@example.com")
  end

  it "reports a single-user instance while keeping the directory payload public" do
    viewer = Factories.user(
      email_address: "solo@example.com",
      name: "",
      github_handle: "solo",
      profile_bio: "Local operator.",
      github_token: "ghp_solo_secret",
      claude_oauth_token: "sk-solo-secret"
    )
    sign_in_as(viewer)

    get "/api/v1/app/profiles"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["team_user_count"]).to eq(1)
    expect(body["profiles"]).to contain_exactly(
      include(
        "id" => viewer.id,
        "display_name" => "@solo",
        "github_handle" => "solo",
        "bio_excerpt" => "Local operator.",
        "profile_path" => "/profiles/#{viewer.id}"
      )
    )
    expect(response.body).not_to include("solo@example.com")
    expect(response.body).not_to include("ghp_solo_secret")
    expect(response.body).not_to include("sk-solo-secret")
  end

  it "shows a teammate profile with safe owned work summaries" do
    viewer = Factories.user
    teammate = Factories.user(
      email_address: "ada@example.com",
      first_name: "Grace",
      last_name: "Hopper",
      github_handle: "@grace",
      profile_bio: "Compiler operator.",
      profile_location: "Arlington",
      profile_company: "Navy",
      profile_website: "https://example.com/grace",
      claude_oauth_token: "sk-profile-secret",
      codex_api_key: "sk-codex-profile-secret",
      codex_auth_json: Factories.codex_auth_json(access_token: "codex-profile-access"),
      github_token: "ghp_profile_secret",
      api_token: "syrus_profile_secret"
    )
    repo = Factories.repository(user: teammate, owner: "navy", name: "cobol")
    epic = Factories.epic(user: teammate, repository: repo, title: "Directory")
    job = Factories.job_record(user: teammate, repository: repo, issue_title: "Link owners")
    sign_in_as(viewer)

    get "/api/v1/app/profiles/#{teammate.id}"

    expect(response).to have_http_status(:ok)
    profile = parse_body["profile"]
    expect(profile).to include(
      "id" => teammate.id,
      "display_name" => "Grace Hopper",
      "github_handle" => "grace",
      "role_label" => "Operator",
      "profile_bio" => "Compiler operator.",
      "profile_location" => "Arlington",
      "profile_company" => "Navy",
      "profile_website" => "https://example.com/grace",
      "profile_path" => "/profiles/#{teammate.id}"
    )
    expect(profile["repositories"]).to include(include("slug" => "navy/cobol", "path" => "/repositories/#{repo.id}"))
    expect(profile["epics"]).to include(include("id" => epic.id, "title" => "Directory", "path" => "/epics/#{epic.id}"))
    expect(profile["jobs"]).to include(include("id" => job.id, "title" => "Link owners", "path" => "/jobs/#{job.id}"))
    expect(profile["recent_activity"].map { |activity| activity["title"] }).to include("Directory", "Link owners")
    expect(profile.keys).not_to include(
      "admin",
      "agent_provider",
      "agent_max_turns",
      "claude_oauth_token",
      "codex_api_key",
      "codex_auth_json",
      "github_token",
      "api_token"
    )
    expect(response.body).not_to include(teammate.email_address)
    expect(response.body).not_to include("sk-profile-secret")
    expect(response.body).not_to include("sk-codex-profile-secret")
    expect(response.body).not_to include("codex-profile-access")
    expect(response.body).not_to include("ghp_profile_secret")
    expect(response.body).not_to include("syrus_profile_secret")
  end

  it "summarizes owned work without exposing private settings" do
    viewer = Factories.user
    teammate = Factories.user(name: "Grace Hopper", github_handle: "grace")
    repository = Factories.repository(user: teammate, owner: "navy", name: "compiler")
    Factories.epic(user: teammate, repository: repository, title: "Profiles")
    closed_job = Factories.job_record(
      user: teammate,
      repository: repository,
      issue_number: 1,
      issue_title: "Retire old forms",
      state: "closed",
      closure_reason: "pr_merged"
    )
    open_job = Factories.job_record(
      user: teammate,
      repository: repository,
      issue_number: 2,
      issue_title: "Add profile page",
      state: "running"
    )
    Factories.job_record(user: viewer, issue_number: 3, issue_title: "Other user's work", state: "queued")
    sign_in_as(viewer)

    get "/api/v1/app/profiles/#{teammate.id}"

    expect(response).to have_http_status(:ok)
    profile = parse_body.fetch("profile")
    expect(profile.fetch("counts")).to include(
      "repositories" => 1,
      "epics" => 1,
      "jobs" => 2,
      "open_jobs" => 1
    )
    expect(profile.fetch("jobs")).to contain_exactly(
      hash_including(
        "id" => open_job.id,
        "title" => "Add profile page",
        "state" => "running",
        "repository" => hash_including("slug" => "navy/compiler"),
        "path" => "/jobs/#{open_job.id}",
        "owner" => {
          "id" => teammate.id,
          "display_name" => "Grace Hopper",
          "profile_path" => "/profiles/#{teammate.id}"
        }
      ),
      hash_including(
        "id" => closed_job.id,
        "title" => "Retire old forms",
        "state" => "closed",
        "repository" => hash_including("slug" => "navy/compiler"),
        "path" => "/jobs/#{closed_job.id}",
        "owner" => {
          "id" => teammate.id,
          "display_name" => "Grace Hopper",
          "profile_path" => "/profiles/#{teammate.id}"
        }
      )
    )
    expect(profile.fetch("recent_activity").map { |activity| activity["title"] }).to include("Add profile page", "Retire old forms")
    expect(response.body).not_to include("Other user's work")
  end

  it "keeps current-user profile work quiet" do
    user = Factories.user(name: "Solo Operator")
    repository = Factories.repository(user: user, owner: "solo", name: "repo")
    Factories.job_record(user: user, repository: repository, issue_number: 1, issue_title: "Own the work", state: "running")
    sign_in_as(user)

    get "/api/v1/app/profiles/#{user.id}"

    expect(response).to have_http_status(:ok)
    recent_job = parse_body.dig("profile", "jobs").sole
    expect(recent_job).to include(
      "title" => "Own the work",
      "repository" => hash_including("slug" => "solo/repo")
    )
    expect(recent_job).not_to have_key("owner")
  end
end
