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
      "profile_bio" => "Compiler operator.",
      "profile_location" => "Arlington",
      "profile_company" => "Navy",
      "profile_website" => "https://example.com/grace"
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
end
