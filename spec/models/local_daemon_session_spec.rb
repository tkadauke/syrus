require "rails_helper"

RSpec.describe LocalDaemonSession, type: :model do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }

  def daemon_session(**attrs)
    LocalDaemonSession.create!({ chat_session: chat, user: user }.merge(attrs))
  end

  it "generates an auth token on create" do
    session = daemon_session
    expect(session.auth_token).to be_present
    expect(session.auth_token.length).to eq(64)
  end

  it "accepts an explicit auth token" do
    session = daemon_session(auth_token: "fixed-token")
    expect(session.auth_token).to eq("fixed-token")
  end

  it "requires a unique auth token" do
    daemon_session(auth_token: "taken")
    duplicate = LocalDaemonSession.new(chat_session: chat, user: user, auth_token: "taken")
    expect(duplicate).not_to be_valid
  end

  it "starts in connected state (disconnected_at nil)" do
    expect(daemon_session.connected?).to be true
    expect(daemon_session.disconnected?).to be false
  end

  it "reports a stale heartbeat when last_heartbeat_at is older than the timeout" do
    session = daemon_session(last_heartbeat_at: (LocalDaemonSession::HEARTBEAT_TIMEOUT + 1.second).ago)
    expect(session.heartbeat_stale?).to be true
  end

  it "does not report a stale heartbeat when last_heartbeat_at is recent" do
    session = daemon_session(last_heartbeat_at: 5.seconds.ago)
    expect(session.heartbeat_stale?).to be false
  end

  it "does not report a stale heartbeat when last_heartbeat_at is nil" do
    session = daemon_session(last_heartbeat_at: nil)
    expect(session.heartbeat_stale?).to be false
  end

  describe "#mark_connected!" do
    it "clears disconnected_at, updates repo/branch, and broadcasts connected status" do
      session = daemon_session(disconnected_at: 1.hour.ago)

      events = []
      allow(AppEvents).to receive(:broadcast) { |**args| events << args }

      session.mark_connected!(repo: "owner/repo", branch: "main")

      expect(session.reload.disconnected_at).to be_nil
      expect(session.daemon_repo).to eq("owner/repo")
      expect(session.daemon_branch).to eq("main")
      expect(chat.reload.daemon_connected).to be true
      expect(chat.daemon_repo).to eq("owner/repo")

      expect(events).to include(a_hash_including(
        type: "updated",
        resource: "chat",
        id: chat.id,
        changed: [ "daemon" ],
        payload: a_hash_including(daemon_status: "connected")
      ))
    end
  end

  describe "#mark_disconnected!" do
    it "sets disconnected_at, marks chat disconnected, and broadcasts" do
      session = daemon_session
      session.mark_connected!(repo: "owner/repo", branch: "main")

      events = []
      allow(AppEvents).to receive(:broadcast) { |**args| events << args }

      session.mark_disconnected!

      expect(session.reload.disconnected_at).not_to be_nil
      expect(chat.reload.daemon_connected).to be false

      expect(events).to include(a_hash_including(
        payload: a_hash_including(daemon_status: "disconnected")
      ))
    end

    it "is idempotent when already disconnected" do
      session = daemon_session(disconnected_at: 5.minutes.ago)
      expect { session.mark_disconnected! }.not_to change { session.reload.disconnected_at }
    end
  end

  describe "#record_heartbeat!" do
    it "updates last_heartbeat_at" do
      session = daemon_session
      freeze_time do
        session.record_heartbeat!
        expect(session.reload.last_heartbeat_at).to be_within(1.second).of(Time.current)
      end
    end
  end

  describe "#pending_tool_calls" do
    it "returns only pending calls in creation order" do
      session = daemon_session
      first = LocalToolCall.create!(
        local_daemon_session: session,
        chat_session: chat,
        tool_use_id: "abc",
        tool_name: "read_file",
        tool_input: { path: "/tmp/a" },
        state: "pending"
      )
      LocalToolCall.create!(
        local_daemon_session: session,
        chat_session: chat,
        tool_use_id: "def",
        tool_name: "read_file",
        tool_input: { path: "/tmp/b" },
        state: "dispatched"
      )

      expect(session.pending_tool_calls.to_a).to eq([ first ])
    end
  end
end
