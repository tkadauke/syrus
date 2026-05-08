require "rails_helper"

RSpec.describe "Admin users", type: :request do
  let!(:admin) { Factories.user }   # first-user auto-promotes — materialize early
  let(:non_admin) { Factories.user }

  describe "GET /admin/users" do
    it "blocks non-admins" do
      sign_in_as(non_admin)
      get "/admin/users"
      expect(response).to redirect_to(root_path)
    end

    it "lists users for admins" do
      sign_in_as(admin)
      Factories.user(email_address: "low@example.com",
                     gh_rate_limit_remaining: 5, gh_rate_limit_limit: 5000)
      get "/admin/users"
      expect(response).to be_successful
      expect(response.body).to include(admin.email_address)
      expect(response.body).to include("low@example.com")
    end

    it "honors ?gh_rate=low filter" do
      sign_in_as(admin)
      ok_user  = Factories.user(email_address: "ok@example.com",
                                 gh_rate_limit_remaining: 4500, gh_rate_limit_limit: 5000)
      low_user = Factories.user(email_address: "low@example.com",
                                 gh_rate_limit_remaining: 5, gh_rate_limit_limit: 5000)
      get "/admin/users", params: { gh_rate: "low" }
      expect(response.body).to include(low_user.email_address)
      expect(response.body).not_to include(ok_user.email_address)
    end

    it "honors ?has_codex_token=true filter" do
      sign_in_as(admin)
      codex_user = Factories.user(email_address: "codex@example.com", codex_api_key: "sk_test")
      codex_login_user = Factories.user(email_address: "codex-login@example.com",
                                        codex_auth_mode: "chatgpt_login",
                                        codex_auth_json: Factories.codex_auth_json(access_token: "access_test"))
      other_user = Factories.user(email_address: "plain@example.com")

      get "/admin/users", params: { has_codex_token: "true" }

      expect(response.body).to include(codex_user.email_address)
      expect(response.body).to include(codex_login_user.email_address)
      expect(response.body).not_to include(other_user.email_address)
    end

    it "shows the empty-state row when filters don't match anything" do
      sign_in_as(admin)
      get "/admin/users", params: { email: "absolutely-no-match-#{SecureRandom.hex(4)}" }
      expect(response.body).to include("No users match these filters")
    end
  end

  describe "GET /admin/users/:id" do
    it "renders user detail with token presence indicators (no plaintext)" do
      sign_in_as(admin)
      target = Factories.user(email_address: "target@example.com",
                              github_token: "ghp_secretvalue",
                              claude_oauth_token: "co_secretvalue",
                              agent_provider: "codex",
                              codex_auth_mode: "chatgpt_login",
                              codex_api_key: "sk_codex_secretvalue",
                              codex_auth_json: Factories.codex_auth_json(access_token: "codex_access_secretvalue"))
      get "/admin/users/#{target.id}"
      expect(response).to be_successful
      expect(response.body).to include("target@example.com")
      expect(response.body).to include("codex")
      expect(response.body).to include("chatgpt_login")
      expect(response.body).to include("set")        # token presence indicator
      expect(response.body).not_to include("ghp_secretvalue")
      expect(response.body).not_to include("co_secretvalue")
      expect(response.body).not_to include("sk_codex_secretvalue")
      expect(response.body).not_to include("codex_access_secretvalue")
    end

    it "404s on unknown id" do
      sign_in_as(admin)
      get "/admin/users/999999"
      expect(response).to have_http_status(:not_found).or have_http_status(:internal_server_error)
    end
  end

  describe "the GH rate-limits tile on /admin" do
    it "links to /admin/users?gh_rate=low" do
      sign_in_as(admin)
      get "/admin"
      expect(response.body).to include(admin_users_path(gh_rate: "low"))
    end
  end

  describe "POST /admin/users/:id/pause_scheduling" do
    let(:target) { Factories.user(email_address: "target@example.com") }

    it "blocks non-admins" do
      sign_in_as(non_admin)
      post "/admin/users/#{target.id}/pause_scheduling"
      expect(response).to redirect_to(root_path)
    end

    it "pauses scheduling for the target user" do
      sign_in_as(admin)
      expect {
        post "/admin/users/#{target.id}/pause_scheduling"
      }.to change { target.reload.scheduling_paused }.from(false).to(true)
      expect(response).to redirect_to(admin_user_path(target))
    end

    it "logs an AdminAction" do
      sign_in_as(admin)
      expect {
        post "/admin/users/#{target.id}/pause_scheduling"
      }.to change { AdminAction.where(action: "pause_user_scheduling").count }.by(1)
    end
  end

  describe "POST /admin/users/:id/unpause_scheduling" do
    let(:target) { Factories.user(email_address: "target@example.com", scheduling_paused: true) }

    it "blocks non-admins" do
      sign_in_as(non_admin)
      post "/admin/users/#{target.id}/unpause_scheduling"
      expect(response).to redirect_to(root_path)
    end

    it "resumes scheduling for the target user" do
      sign_in_as(admin)
      expect {
        post "/admin/users/#{target.id}/unpause_scheduling"
      }.to change { target.reload.scheduling_paused }.from(true).to(false)
      expect(response).to redirect_to(admin_user_path(target))
    end

    it "logs an AdminAction" do
      sign_in_as(admin)
      expect {
        post "/admin/users/#{target.id}/unpause_scheduling"
      }.to change { AdminAction.where(action: "unpause_user_scheduling").count }.by(1)
    end
  end
end
