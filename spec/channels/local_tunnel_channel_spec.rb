require "rails_helper"

RSpec.describe LocalTunnelChannel, type: :channel do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, mode: "local") }

  before do
    stub_connection current_user: user
    enable_local_mode
  end

  def enable_local_mode
    feature = Feature.find_or_initialize_by(slug: "local_mode")
    feature.update!(category: "Labs", name: "Local Mode", enabled: true)
  end

  def daemon_session(**attrs)
    chat_session.create_local_daemon_session!({
      user: user,
      auth_token: "daemon-token-123"
    }.merge(attrs))
  end

  describe "subscribed" do
    it "rejects when the local_mode feature is disabled" do
      Feature.find_by!(slug: "local_mode").update!(enabled: false)
      session = daemon_session

      subscribe(daemon_session_id: session.id, auth_token: "daemon-token-123")

      expect(subscription).to be_rejected
    end

    it "rejects for unknown daemon session IDs" do
      subscribe(daemon_session_id: 99_999, auth_token: "daemon-token-123")

      expect(subscription).to be_rejected
    end

    it "rejects for sessions owned by another user" do
      other_user = Factories.user
      other_chat = ChatSession.create!(user: other_user, mode: "local")
      other_session = other_chat.create_local_daemon_session!(user: other_user, auth_token: "tok")

      subscribe(daemon_session_id: other_session.id, auth_token: "tok")

      expect(subscription).to be_rejected
    end

    it "rejects when the auth token does not match" do
      session = daemon_session

      subscribe(daemon_session_id: session.id, auth_token: "wrong-token")

      expect(subscription).to be_rejected
    end

    it "confirms and marks the session connected on valid subscription" do
      session = daemon_session

      subscribe(daemon_session_id: session.id, auth_token: "daemon-token-123")

      expect(subscription).to be_confirmed
      expect(session.reload.connected_at).to be_present
      expect(session.reload.disconnected_at).to be_nil
    end

    it "clears a stale disconnected_at on reconnect" do
      session = daemon_session(disconnected_at: 1.minute.ago)

      subscribe(daemon_session_id: session.id, auth_token: "daemon-token-123")

      expect(subscription).to be_confirmed
      expect(session.reload.disconnected_at).to be_nil
    end

    it "delivers pending tool calls to the daemon on subscribe" do
      session = daemon_session(connected_at: Time.current)
      call = session.tool_calls.create!(tool_name: "git_status", arguments: {})

      subscribe(daemon_session_id: session.id, auth_token: "daemon-token-123")

      expect(transmissions).to include(
        include("type" => "tool_call", "id" => call.id, "tool" => "git_status")
      )
      expect(call.reload.dispatched_at).to be_present
    end
  end

  describe "unsubscribed" do
    it "disconnects the daemon session when the channel closes" do
      session = daemon_session(connected_at: Time.current)
      subscribe(daemon_session_id: session.id, auth_token: "daemon-token-123")

      unsubscribe

      expect(session.reload.disconnected_at).to be_present
    end
  end

  describe "ping" do
    it "updates last_ping_at and transmits pong" do
      session = daemon_session
      subscribe(daemon_session_id: session.id, auth_token: "daemon-token-123")

      perform :ping

      expect(transmissions).to include(include("type" => "pong"))
      expect(session.reload.last_ping_at).to be_present
    end
  end

  describe "tool_result" do
    it "marks a tool call completed with a successful result" do
      session = daemon_session(connected_at: Time.current)
      subscribe(daemon_session_id: session.id, auth_token: "daemon-token-123")
      call = session.tool_calls.create!(tool_name: "read_file", arguments: { path: "README.md" })

      perform :tool_result, { "id" => call.id, "result" => { "content" => "# Hello" } }

      call.reload
      expect(call.result).to eq({ "content" => "# Hello" })
      expect(call.error).to be_nil
      expect(call.completed_at).to be_present
    end

    it "marks a tool call completed with an error" do
      session = daemon_session(connected_at: Time.current)
      subscribe(daemon_session_id: session.id, auth_token: "daemon-token-123")
      call = session.tool_calls.create!(tool_name: "read_file", arguments: { path: "missing.rb" })

      perform :tool_result, { "id" => call.id, "error" => "file not found" }

      call.reload
      expect(call.error).to eq("file not found")
      expect(call.completed_at).to be_present
    end

    it "ignores results for unknown tool call IDs" do
      session = daemon_session(connected_at: Time.current)
      subscribe(daemon_session_id: session.id, auth_token: "daemon-token-123")

      expect { perform :tool_result, { "id" => 99_999, "result" => {} } }.not_to raise_error
    end
  end
end
