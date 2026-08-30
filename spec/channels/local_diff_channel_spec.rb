require "rails_helper"

RSpec.describe LocalDiffChannel, type: :channel do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, mode: "local") }

  before do
    stub_connection current_user: user
  end

  def enable_local_mode
    feature = Feature.find_or_initialize_by(slug: "local_mode")
    feature.update!(category: "Labs", name: "Local Mode", enabled: true)
  end

  def create_daemon_session(chat: chat_session, connected: true)
    LocalDaemonSession.create!(
      chat_session: chat,
      user: chat.user,
      disconnected_at: connected ? nil : 1.minute.ago
    )
  end

  it "rejects subscriptions when the local_mode feature is disabled" do
    subscribe(chat_id: chat_session.id)

    expect(subscription).to be_rejected
  end

  it "rejects subscriptions without a chat id" do
    enable_local_mode

    subscribe

    expect(subscription).to be_rejected
  end

  it "rejects subscriptions for another user's chat" do
    enable_local_mode
    other_chat = ChatSession.create!(user: Factories.user, mode: "local")

    subscribe(chat_id: other_chat.id)

    expect(subscription).to be_rejected
  end

  it "streams from the chat-scoped local diff channel key" do
    enable_local_mode
    create_daemon_session
    allow(Mcp::Tools::LocalToolDispatch).to receive(:call).and_return(Mcp::Tools.success(diff: ""))

    subscribe(chat_id: chat_session.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("local_diff:#{user.id}:#{chat_session.id}")
  end

  context "with an active subscription and local_mode enabled" do
    before { enable_local_mode }

    describe "on subscribe" do
      it "dispatches git_diff through the current chat's local daemon session" do
        create_daemon_session
        expect(Mcp::Tools::LocalToolDispatch).to receive(:call)
          .with("git_diff", {}, chat_session: chat_session)
          .and_return(Mcp::Tools.success(diff: "diff --git a/foo.rb b/foo.rb\n"))

        subscribe(chat_id: chat_session.id)

        expect(transmissions.last).to include(
          "type" => "diff_result",
          "diff" => "diff --git a/foo.rb b/foo.rb\n",
          "mode" => "head",
          "error" => nil
        )
      end

      it "transmits not_connected when no daemon session is active" do
        subscribe(chat_id: chat_session.id)

        expect(transmissions.last).to include(
          "type" => "diff_result",
          "diff" => nil,
          "mode" => "head",
          "error" => "not_connected"
        )
      end
    end

    describe "receive (refresh request)" do
      before do
        create_daemon_session
        allow(Mcp::Tools::LocalToolDispatch).to receive(:call).and_return(Mcp::Tools.success(diff: ""))
        subscribe(chat_id: chat_session.id)
        transmissions.clear
      end

      it "dispatches git_diff for head mode" do
        expect(Mcp::Tools::LocalToolDispatch).to receive(:call)
          .with("git_diff", {}, chat_session: chat_session)
          .and_return(Mcp::Tools.success(diff: "head diff"))

        perform :receive, { "mode" => "head" }

        expect(transmissions.last).to include("diff" => "head diff", "mode" => "head", "error" => nil)
      end

      it "dispatches git_diff_staged for staged mode" do
        expect(Mcp::Tools::LocalToolDispatch).to receive(:call)
          .with("git_diff_staged", {}, chat_session: chat_session)
          .and_return(Mcp::Tools.success(diff: "staged diff"))

        perform :receive, { "mode" => "staged" }

        expect(transmissions.last).to include("diff" => "staged diff", "mode" => "staged", "error" => nil)
      end

      it "defaults to head mode for unknown mode values" do
        expect(Mcp::Tools::LocalToolDispatch).to receive(:call)
          .with("git_diff", {}, chat_session: chat_session)
          .and_return(Mcp::Tools.success(diff: "head diff"))

        perform :receive, { "mode" => "unknown_mode" }

        expect(transmissions.last).to include("diff" => "head diff", "mode" => "head", "error" => nil)
      end

      it "transmits dispatcher errors" do
        expect(Mcp::Tools::LocalToolDispatch).to receive(:call)
          .with("git_diff_staged", {}, chat_session: chat_session)
          .and_return(Mcp::Tools.tool_error("boom"))

        perform :receive, { "mode" => "staged" }

        expect(transmissions.last).to include("diff" => nil, "mode" => "staged", "error" => "boom")
      end
    end

    it "ignores disconnected daemon sessions" do
      create_daemon_session(connected: false)

      subscribe(chat_id: chat_session.id)

      expect(transmissions.last).to include("error" => "not_connected")
    end
  end
end
