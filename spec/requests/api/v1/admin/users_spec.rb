require "rails_helper"

RSpec.describe "API: /api/v1/admin/users", type: :request do
  # Materialize admin (and its token) before any other user creation
  # so the first-user-is-admin promotion lands on us.
  let!(:admin) { Factories.user }
  let!(:admin_token) { admin.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  describe "GET /api/v1/admin/users" do
    it "401s without a token" do
      get "/api/v1/admin/users"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the user list with a row per user (no plaintext tokens)" do
      Factories.user(email_address: "alice@example.com", github_token: "ghp_secret",
                     agent_provider: "codex",
                     codex_auth_mode: "chatgpt_login",
                     codex_api_key: "sk_codex_secret",
                     codex_auth_json: Factories.codex_auth_json(access_token: "codex_access_secret"))
      get "/api/v1/admin/users", headers: auth
      expect(response).to be_successful, "expected success, got #{response.status}: #{response.body}"
      body = parse_body
      expect(body["users"]).to be_an(Array)
      alice = body["users"].find { |u| u["email_address"] == "alice@example.com" }
      expect(alice).to include(
        "agent_provider" => "codex",
        "codex_auth_mode" => "chatgpt_login",
        "has_github_token" => true,
        "has_codex_token" => true,
        "has_codex_api_key" => true,
        "has_codex_auth_json" => true
      )
      expect(response.body).not_to include("ghp_secret")
      expect(response.body).not_to include("sk_codex_secret")
      expect(response.body).not_to include("codex_access_secret")
    end

    it "includes GitHub API block state without exposing tokens" do
      blocked = Factories.user(email_address: "blocked@example.com",
                               github_token: "ghp_secret",
                               gh_api_blocked_at: 1.minute.ago,
                               gh_api_blocked_reason: "API rate limit exceeded",
                               gh_rate_limit_remaining: 0,
                               gh_rate_limit_limit: 5_000,
                               gh_rate_limit_resource: "core")

      get "/api/v1/admin/users", headers: auth
      row = parse_body["users"].find { |u| u["id"] == blocked.id }

      expect(row).to include(
        "github_api_blocked" => true,
        "github_api_blocked_reason" => "API rate limit exceeded"
      )
      expect(row["github_rate_limit"]).to include(
        "remaining" => 0,
        "limit" => 5_000,
        "resource" => "core"
      )
      expect(response.body).not_to include("ghp_secret")
    end

    it "applies the same filters as the HTML view" do
      Factories.user(email_address: "ok@example.com",
                      gh_rate_limit_remaining: 4500, gh_rate_limit_limit: 5000)
      Factories.user(email_address: "low@example.com",
                      gh_rate_limit_remaining: 5, gh_rate_limit_limit: 5000)

      get "/api/v1/admin/users", params: { gh_rate: "low" }, headers: auth
      emails = parse_body["users"].map { |u| u["email_address"] }
      expect(emails).to include("low@example.com")
      expect(emails).not_to include("ok@example.com")
    end

    it "echoes the active filters back" do
      get "/api/v1/admin/users", params: { gh_rate: "low", admin: "true", has_codex_token: "false" }, headers: auth
      expect(parse_body["filters"]).to eq("admin" => "yes", "has_codex_token" => "no", "gh_rate" => "low")
    end
  end

  describe "GET /api/v1/admin/users/:id" do
    it "returns the user detail payload" do
      target = Factories.user(email_address: "target@example.com",
                               gh_rate_limit_remaining: 100, gh_rate_limit_limit: 5000,
                               gh_rate_limit_resource: "core")
      get "/api/v1/admin/users/#{target.id}", headers: auth
      expect(response).to be_successful
      body = parse_body
      expect(body).to include(
        "email_address" => "target@example.com",
        "admin"         => false
      )
      expect(body["github_rate_limit"]).to include(
        "remaining" => 100, "limit" => 5000, "resource" => "core"
      )
      expect(body["github_api_blocked"]).to be false
      expect(body["recent_jobs"]).to eq([])
      expect(body["recent_runs"]).to eq([])
    end

    it "does not expose private chat or whiteboard records in the external user detail API" do
      target = Factories.user(email_address: "target@example.com")
      chat = ChatSession.create!(user: target, title: "Private planning chat")
      chat.messages.create!(role: "user", content: { "text" => "Private transcript text" })
      chat.create_whiteboard!(
        scene_json: { "elements" => [ { "id" => "private-whiteboard-box" } ], "appState" => {}, "files" => {} },
        version: 2
      )

      get "/api/v1/admin/users/#{target.id}", headers: auth

      expect(response).to be_successful
      body = parse_body
      expect(body.keys).not_to include("chat_sessions", "chats", "whiteboards")
      expect(response.body).not_to include("Private planning chat")
      expect(response.body).not_to include("Private transcript text")
      expect(response.body).not_to include("private-whiteboard-box")
    end

    it "404s with a JSON error on unknown id" do
      get "/api/v1/admin/users/999999", headers: auth
      expect(response).to have_http_status(:not_found)
    end
  end
end
