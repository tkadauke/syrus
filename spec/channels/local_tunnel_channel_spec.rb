require "rails_helper"

RSpec.describe LocalTunnelChannel, type: :channel do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }
  let(:daemon_session) do
    LocalDaemonSession.create!(
      chat_session: chat,
      user: user,
      auth_token: "test-tunnel-token"
    )
  end

  before do
    stub_connection current_user: user
    # Prevent background threads from firing in most specs
    allow_any_instance_of(described_class).to receive(:start_heartbeat_thread)
    allow_any_instance_of(described_class).to receive(:start_dispatch_thread)
    allow_any_instance_of(described_class).to receive(:drain_queued_tool_calls)
  end

  def enable_local_mode
    feature = Feature.find_or_initialize_by(slug: "local_mode")
    feature.update!(category: "Labs", name: "Local Mode", enabled: true)
  end

  def subscribe_to(session)
    subscribe(chat_session_id: session.chat_session_id, tunnel_token: session.auth_token)
  end

  it "rejects when the local_mode feature is disabled" do
    subscribe_to(daemon_session)
    expect(subscription).to be_rejected
  end

  it "rejects when no matching daemon session exists" do
    enable_local_mode
    subscribe(chat_session_id: chat.id, tunnel_token: "wrong-token")
    expect(subscription).to be_rejected
  end

  it "rejects when the daemon session belongs to another user" do
    enable_local_mode
    other_user = Factories.user
    other_chat = ChatSession.create!(user: other_user)
    other_session = LocalDaemonSession.create!(
      chat_session: other_chat,
      user: other_user,
      auth_token: "other-token"
    )
    subscribe(chat_session_id: other_chat.id, tunnel_token: "other-token")
    expect(subscription).to be_rejected
  end

  it "rejects when the daemon session is already disconnected" do
    enable_local_mode
    daemon_session.mark_disconnected!
    subscribe_to(daemon_session)
    expect(subscription).to be_rejected
  end

  it "confirms subscription when feature is enabled and token matches" do
    enable_local_mode
    subscribe_to(daemon_session)
    expect(subscription).to be_confirmed
  end

  it "streams from the per-session tool-call broadcast channel" do
    enable_local_mode
    subscribe_to(daemon_session)
    expect(subscription).to have_stream_for("local_daemon_session_#{daemon_session.id}_tool_calls")
  end

  it "stops background threads and marks daemon disconnected on unsubscribe" do
    enable_local_mode
    subscribe_to(daemon_session)

    # Unsubscribed should call mark_disconnected!
    allow_any_instance_of(described_class).to receive(:stop_threads)
    unsubscribe

    expect(daemon_session.reload.disconnected_at).not_to be_nil
  end

  describe "receiving messages" do
    before { enable_local_mode }

    it "marks the session connected with repo and branch on connect message" do
      subscribe_to(daemon_session)

      perform :receive, { "type" => "connect", "repo" => "owner/repo", "branch" => "feat" }

      expect(daemon_session.reload.daemon_repo).to eq("owner/repo")
      expect(daemon_session.reload.daemon_branch).to eq("feat")
      expect(chat.reload.daemon_connected).to be true
    end

    it "transmits a connected frame on connect message" do
      subscribe_to(daemon_session)

      perform :receive, { "type" => "connect", "repo" => "owner/repo", "branch" => "main" }

      expect(transmissions).to include({ "type" => "connected" })
    end

    it "updates last_heartbeat_at on pong message" do
      subscribe_to(daemon_session)

      freeze_time do
        perform :receive, { "type" => "pong" }
        expect(daemon_session.reload.last_heartbeat_at).to be_within(1.second).of(Time.current)
      end
    end

    it "completes the matching tool call on tool_result message" do
      subscribe_to(daemon_session)
      tool_call = LocalToolCall.create!(
        local_daemon_session: daemon_session,
        chat_session: chat,
        tool_use_id: "call-abc",
        tool_name: "read_file",
        tool_input: { path: "/repo/README.md" },
        state: "dispatched"
      )

      perform :receive, {
        "type"        => "tool_result",
        "tool_use_id" => "call-abc",
        "content"     => [{ "type" => "text", "text" => "# Project" }]
      }

      expect(tool_call.reload.state).to eq("completed")
      expect(tool_call.result).to eq([{ "type" => "text", "text" => "# Project" }])
    end

    it "fails the tool call when tool_result has no content" do
      subscribe_to(daemon_session)
      tool_call = LocalToolCall.create!(
        local_daemon_session: daemon_session,
        chat_session: chat,
        tool_use_id: "call-xyz",
        tool_name: "run_command",
        tool_input: { command: "ls" },
        state: "dispatched"
      )

      perform :receive, { "type" => "tool_result", "tool_use_id" => "call-xyz" }

      expect(tool_call.reload.state).to eq("failed")
    end

    it "ignores tool_result for an unknown tool_use_id" do
      subscribe_to(daemon_session)
      expect {
        perform :receive, { "type" => "tool_result", "tool_use_id" => "unknown", "content" => [] }
      }.not_to raise_error
    end
  end

  describe "tool call dispatch" do
    before { enable_local_mode }

    it "drains pending tool calls on connect and transmits them" do
      subscribe_to(daemon_session)
      allow(daemon_session).to receive(:mark_connected!)

      # Restore real drain so we can observe it
      allow_any_instance_of(described_class).to receive(:drain_queued_tool_calls).and_call_original

      tool_call = LocalToolCall.create!(
        local_daemon_session: daemon_session,
        chat_session: chat,
        tool_use_id: "call-1",
        tool_name: "list_files",
        tool_input: { path: "/repo" },
        state: "pending"
      )

      perform :receive, { "type" => "connect", "repo" => "r", "branch" => "b" }

      tool_call_frame = transmissions.find { |t| t["type"] == "tool_call" }
      expect(tool_call_frame).to include(
        "type"        => "tool_call",
        "tool_use_id" => "call-1",
        "tool"        => "list_files"
      )
      expect(tool_call.reload.state).to eq("dispatched")
    end
  end

  describe "heartbeat timeout" do
    before { enable_local_mode }

    it "marks daemon disconnected and transmits a disconnected frame when heartbeat is stale" do
      # Make the session appear old so heartbeat_stale? returns true immediately.
      daemon_session.update_columns(updated_at: 2.minutes.ago)

      allow_any_instance_of(described_class).to receive(:start_heartbeat_thread).and_call_original
      stub_const("#{described_class}::HEARTBEAT_INTERVAL", 0.01.seconds)

      subscribe_to(daemon_session)
      sleep 0.1

      expect(daemon_session.reload.disconnected_at).not_to be_nil
      expect(transmissions).to include({ "type" => "disconnected", "reason" => "heartbeat_timeout" })
    end
  end
end
