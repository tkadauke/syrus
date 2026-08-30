require "rails_helper"

RSpec.describe "App API local daemon sessions", type: :request do
  let(:user) { Factories.user }

  before { allow(Feature).to receive(:local_mode_enabled?).and_return(true) }

  def parse_body = JSON.parse(response.body)
  def daemon_session_path(chat_session) = "/api/v1/app/chats/#{chat_session.id}/local_daemon_session"

  describe "GET /api/v1/app/chats/:chat_id/local_daemon_session" do
    it "404s when no daemon session exists yet" do
      sign_in_as(user)
      chat = ChatSession.create!(user: user, mode: "local")

      get daemon_session_path(chat)

      expect(response).to have_http_status(:not_found)
    end

    it "returns the existing daemon session" do
      sign_in_as(user)
      chat = ChatSession.create!(user: user, mode: "local")
      session = LocalDaemonSession.create!(chat_session: chat, user: user)

      get daemon_session_path(chat)

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("daemon_session", "id")).to eq(session.id)
    end

    it "404s for a soft-deleted chat" do
      sign_in_as(user)
      chat = ChatSession.create!(user: user, mode: "local")
      LocalDaemonSession.create!(chat_session: chat, user: user)
      chat.soft_delete_by!(user)

      get daemon_session_path(chat)

      expect(response).to have_http_status(:not_found)
    end

    it "404s when Local Mode is not enabled" do
      allow(Feature).to receive(:local_mode_enabled?).and_return(false)
      sign_in_as(user)
      chat = ChatSession.create!(user: user, mode: "local")

      get daemon_session_path(chat)

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("local_mode_disabled")
    end
  end

  describe "POST /api/v1/app/chats/:chat_id/local_daemon_session" do
    it "creates a daemon session with an auth token" do
      sign_in_as(user)
      chat = ChatSession.create!(user: user, mode: "local")

      expect {
        post daemon_session_path(chat)
      }.to change(LocalDaemonSession, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(parse_body.dig("daemon_session", "auth_token")).to be_present
    end

    it "returns the reconnect command without marking a disconnected daemon connected" do
      sign_in_as(user)
      chat = ChatSession.create!(user: user, mode: "local", local_daemon_state: "disconnected")
      session = LocalDaemonSession.create!(
        chat_session: chat,
        user: user,
        auth_token: "reconnect-token",
        disconnected_at: 1.minute.ago
      )

      post daemon_session_path(chat)

      expect(response).to have_http_status(:created)
      expect(parse_body.dig("daemon_session", "auth_token")).to eq("reconnect-token")
      expect(parse_body.dig("daemon_session", "connected")).to be(false)
      expect(session.reload).to be_disconnected
      expect(chat.reload.local_daemon_state).to eq("disconnected")
    end
  end
end
