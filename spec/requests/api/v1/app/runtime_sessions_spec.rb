require "rails_helper"

RSpec.describe "App API runtime sessions", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

  before do
    enable_coding_mode!
    register_stub_runtime_provider!
  end

  def build_runtime_session(**attrs)
    RuntimeSession.create!(
      { repository: repository, chat_session: chat_session, workspace_ref: "a", provider_key: "stub", display_name: "Stub", state: "running", primary: true }.merge(attrs)
    )
  end

  def parse_body = JSON.parse(response.body)

  describe "GET /api/v1/app/chats/:chat_id/runtime_sessions" do
    it "lists runtime sessions for the chat" do
      sign_in_as(user)
      session = build_runtime_session

      get "/api/v1/app/chats/#{chat_session.id}/runtime_sessions"

      expect(response).to have_http_status(:ok)
      expect(parse_body["runtime_sessions"].map { |s| s["id"] }).to eq([ session.id ])
    end

    it "404s when Coding Mode is disabled" do
      allow(Feature).to receive(:coding_mode_enabled?).and_return(false)
      sign_in_as(user)

      get "/api/v1/app/chats/#{chat_session.id}/runtime_sessions"

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("feature_disabled")
    end

    it "404s for a planning-mode chat" do
      sign_in_as(user)
      planning_chat = ChatSession.create!(user: user, repository: repository, mode: "planning")

      get "/api/v1/app/chats/#{planning_chat.id}/runtime_sessions"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/app/chats/:chat_id/runtime_sessions/:id" do
    it "returns the session payload" do
      sign_in_as(user)
      session = build_runtime_session

      get "/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{session.id}"

      expect(response).to have_http_status(:ok)
      expect(parse_body).to include("id" => session.id, "state" => "running", "provider_key" => "stub")
    end
  end

  describe "GET /api/v1/app/chats/:chat_id/runtime_sessions/:id/logs" do
    it "delegates to the provider with the given cursor" do
      sign_in_as(user)
      session = build_runtime_session

      get "/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{session.id}/logs", params: { cursor: 3 }

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("entries" => [ "line-3" ], "cursor" => 4)
    end
  end

  describe "POST /api/v1/app/chats/:chat_id/runtime_sessions/:id/capture" do
    it "calls the provider's snapshot and returns the refreshed session" do
      sign_in_as(user)
      session = build_runtime_session

      post "/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{session.id}/capture"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("runtime_session", "id")).to eq(session.id)
    end
  end

  describe "GET /api/v1/app/chats/:chat_id/runtime_sessions/:id/frame" do
    it "streams the latest captured frame document" do
      sign_in_as(user)
      document = Document.new(kind: "file", attachable: user, user: user, title: "Frame", filename: "frame.png", content_type: "image/png")
      document.file.attach(io: StringIO.new("\x89PNG".b), filename: "frame.png", content_type: "image/png")
      document.save!
      session = build_runtime_session(metadata: { "latest_frame_document_id" => document.id })

      get "/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{session.id}/frame"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to eq("image/png")
    end

    it "404s when no frame has been captured yet" do
      sign_in_as(user)
      session = build_runtime_session

      get "/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{session.id}/frame"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/app/chats/:chat_id/runtime_sessions/:id/take_control" do
    it "aborts an active agent lease and acquires one for the operator" do
      sign_in_as(user)
      session = build_runtime_session
      agent_lease = RuntimeControlLease.acquire!(runtime_session: session, owner: "agent", mode: "input", reason: "typing")

      post "/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{session.id}/take_control", params: { reason: "operator check" }

      expect(response).to have_http_status(:ok)
      expect(agent_lease.reload.state).to eq("cancelled")
      expect(parse_body.dig("lease", "owner")).to eq("user")
      expect(parse_body.dig("lease", "owner_ref")).to eq("operator:#{user.id}")
      expect(parse_body.dig("lease", "reason")).to eq("operator check")
    end

    it "rejects an unknown mode" do
      sign_in_as(user)
      session = build_runtime_session

      post "/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{session.id}/take_control", params: { mode: "flying" }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/app/chats/:chat_id/runtime_sessions/:id/release_control" do
    it "releases the operator's own active lease" do
      sign_in_as(user)
      session = build_runtime_session
      lease = RuntimeControlLease.acquire!(runtime_session: session, owner: "user", owner_ref: "operator:#{user.id}", mode: "input", reason: "checking")

      post "/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{session.id}/release_control"

      expect(response).to have_http_status(:ok)
      expect(lease.reload.state).to eq("released")
      expect(parse_body["released"].size).to eq(1)
    end

    it "is a no-op when the operator holds no lease" do
      sign_in_as(user)
      session = build_runtime_session

      post "/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{session.id}/release_control"

      expect(response).to have_http_status(:ok)
      expect(parse_body["released"]).to eq([])
    end
  end
end
