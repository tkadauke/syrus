require "rails_helper"

RSpec.describe LocalDaemonSession do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  def daemon_session(**attrs)
    chat_session.create_local_daemon_session!({
      user: user,
      auth_token: "secure-token-abc"
    }.merge(attrs))
  end

  describe "#connected?" do
    it "returns false when connected_at is nil" do
      session = daemon_session

      expect(session.connected?).to be(false)
    end

    it "returns false when disconnected_at is set" do
      session = daemon_session(connected_at: Time.current, disconnected_at: Time.current)

      expect(session.connected?).to be(false)
    end

    it "returns true when connected and last_ping_at is recent" do
      session = daemon_session(connected_at: Time.current, last_ping_at: 10.seconds.ago)

      expect(session.connected?).to be(true)
    end

    it "returns false when last_ping_at is past the timeout" do
      session = daemon_session(connected_at: Time.current, last_ping_at: (LocalDaemonSession::PING_TIMEOUT + 1.second).ago)

      expect(session.connected?).to be(false)
    end

    it "returns true when connected and last_ping_at is nil (daemon hasn't pinged yet)" do
      session = daemon_session(connected_at: Time.current)

      expect(session.connected?).to be(true)
    end
  end

  describe "#disconnect!" do
    it "sets disconnected_at" do
      session = daemon_session(connected_at: Time.current)
      freeze_time = Time.current

      travel_to(freeze_time) { session.disconnect! }

      expect(session.reload.disconnected_at).to be_within(1.second).of(freeze_time)
    end
  end

  describe "#dispatch_tool_call!" do
    it "creates a tool call record and broadcasts to the daemon channel" do
      session = daemon_session(connected_at: Time.current)
      broadcast_messages = []
      allow(ActionCable.server).to receive(:broadcast) { |channel, data| broadcast_messages << { channel: channel, data: data } }

      call = session.dispatch_tool_call!("read_file", { path: "app/models/user.rb" })

      expect(call).to be_a(LocalToolCall)
      expect(call.tool_name).to eq("read_file")
      expect(call.arguments).to eq({ "path" => "app/models/user.rb" })
      expect(call.dispatched_at).to be_present
      expect(broadcast_messages).to contain_exactly(
        include(
          channel: "local_tunnel_#{session.id}",
          data: include(type: "tool_call", tool: "read_file")
        )
      )
    end
  end

  describe "ChatSession#local_daemon_session association" do
    it "is accessible via chat_session" do
      session = daemon_session

      expect(chat_session.local_daemon_session).to eq(session)
    end

    it "is destroyed when the chat session is destroyed" do
      daemon_session
      session_id = chat_session.local_daemon_session.id

      chat_session.destroy!

      expect(LocalDaemonSession.find_by(id: session_id)).to be_nil
    end
  end
end
