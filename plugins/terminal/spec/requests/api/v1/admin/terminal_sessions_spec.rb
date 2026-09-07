require "rails_helper"

RSpec.describe "API: /api/v1/admin/terminal_sessions", type: :request do
  let!(:admin)        { Factories.user }
  let!(:admin_token)  { admin.generate_api_token! }
  let(:non_admin)     { Factories.user }
  let(:non_admin_tok) { non_admin.generate_api_token! }
  let(:owner)         { Factories.user }

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  before do
    PluginRecord.find_or_create_by!(name: "terminal").update!(enabled: true, disableable: true)
  end

  def build_terminal_session(user:, **attrs)
    Terminal::Session.create!(
      user: user,
      name: "Shell",
      working_directory: "/tmp/shell",
      auth_token: SecureRandom.hex(32),
      started_at: Time.current,
      **attrs
    )
  end

  describe "auth" do
    it "401s without a token" do
      get "/api/v1/admin/terminal_sessions"
      expect(response).to have_http_status(:unauthorized)
    end

    it "403s for a non-admin token" do
      get "/api/v1/admin/terminal_sessions", headers: auth(non_admin_tok)
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "returns plugin_disabled for every endpoint when the terminal plugin is disabled" do
    session = build_terminal_session(user: owner)
    PluginRecord.find_by!(name: "terminal").update!(enabled: false)

    get "/api/v1/admin/terminal_sessions", headers: auth
    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")

    get "/api/v1/admin/terminal_sessions/#{session.id}", headers: auth
    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")

    post "/api/v1/admin/terminal_sessions/#{session.id}/kill", headers: auth
    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  describe "GET /api/v1/admin/terminal_sessions" do
    it "lists sessions across every user with relay_address, hostname, and age" do
      running = build_terminal_session(user: owner, relay_address: "10.0.0.5:41000", started_at: 90.seconds.ago)
      build_terminal_session(user: owner, relay_address: "10.0.0.5:41001", started_at: 2.hours.ago, finished_at: 1.hour.ago, outcome: "exited")

      get "/api/v1/admin/terminal_sessions", headers: auth

      expect(response).to have_http_status(:ok)
      row = parse_body["sessions"].find { |s| s["id"] == running.id }
      expect(row).to include(
        "relay_address" => "10.0.0.5:41000",
        "hostname" => "10.0.0.5",
        "state" => "running",
        "user" => { "id" => owner.id, "email_address" => owner.email_address }
      )
      expect(row["age_s"]).to be >= 90
      expect(row).not_to have_key("auth_token")
      expect(parse_body["total"]).to eq(2)
    end

    it "filters by state" do
      running = build_terminal_session(user: owner)
      finished = build_terminal_session(user: owner, finished_at: Time.current, outcome: "exited")

      get "/api/v1/admin/terminal_sessions", params: { state: "running" }, headers: auth
      ids = parse_body["sessions"].map { |s| s["id"] }
      expect(ids).to     include(running.id)
      expect(ids).not_to include(finished.id)
    end

    it "filters by user" do
      mine = build_terminal_session(user: owner)
      build_terminal_session(user: non_admin)

      get "/api/v1/admin/terminal_sessions", params: { user: owner.email_address }, headers: auth
      ids = parse_body["sessions"].map { |s| s["id"] }
      expect(ids).to eq([ mine.id ])
    end

    it "filters by hostname" do
      matching = build_terminal_session(user: owner, relay_address: "10.0.0.5:41000")
      build_terminal_session(user: owner, relay_address: "10.0.0.9:41000")

      get "/api/v1/admin/terminal_sessions", params: { hostname: "10.0.0.5" }, headers: auth
      ids = parse_body["sessions"].map { |s| s["id"] }
      expect(ids).to eq([ matching.id ])
    end
  end

  describe "GET /api/v1/admin/terminal_sessions/:id" do
    it "returns one session regardless of owning user" do
      session = build_terminal_session(user: owner)

      get "/api/v1/admin/terminal_sessions/#{session.id}", headers: auth

      expect(response).to have_http_status(:ok)
      expect(parse_body).to include("id" => session.id, "user" => { "id" => owner.id, "email_address" => owner.email_address })
    end
  end

  describe "POST /api/v1/admin/terminal_sessions/:id/kill" do
    it "kills another user's session the same way the app path does" do
      session = build_terminal_session(user: owner)

      post "/api/v1/admin/terminal_sessions/#{session.id}/kill", headers: auth

      expect(response).to have_http_status(:ok)
      expect(session.reload.outcome).to eq("killed")
      expect(session.finished_at).to be_present
      expect(parse_body["outcome"]).to eq("killed")
      expect(parse_body["state"]).to eq("finished")
    end

    it "is a no-op on an already-finished session" do
      session = build_terminal_session(user: owner, finished_at: 1.hour.ago, outcome: "exited")

      post "/api/v1/admin/terminal_sessions/#{session.id}/kill", headers: auth

      expect(response).to have_http_status(:ok)
      expect(session.reload.outcome).to eq("exited")
    end
  end
end
