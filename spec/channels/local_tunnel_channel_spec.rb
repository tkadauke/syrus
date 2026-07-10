require "rails_helper"

RSpec.describe LocalTunnelChannel, type: :channel do
  let(:user) { Factories.user }

  before do
    stub_connection current_user: user
  end

  def enable_local_mode
    feature = Feature.find_or_initialize_by(slug: "local_mode")
    feature.update!(category: "Labs", name: "Local Mode", enabled: true)
  end

  it "rejects subscriptions when the local_mode feature is disabled" do
    subscribe

    expect(subscription).to be_rejected
  end

  it "confirms subscriptions when the local_mode feature is enabled" do
    enable_local_mode

    subscribe

    expect(subscription).to be_confirmed
  end

  it "streams from the user's local tunnel channel key" do
    enable_local_mode

    subscribe

    expect(subscription).to have_stream_from("local_tunnel:#{user.id}")
  end

  context "with an active subscription" do
    before { enable_local_mode }

    describe "register message" do
      it "creates a new tunnel session and transmits registered confirmation" do
        subscribe

        perform :receive, { "type" => "register", "repo_slug" => "acme/widget", "branch" => "main" }

        session = LocalTunnelSession.find_by(user: user)
        expect(session).to be_present
        expect(session.repo_slug).to eq("acme/widget")
        expect(session.branch).to eq("main")
        expect(session.status).to eq("connected")
        expect(session.connected_at).to be_present

        expect(transmissions.last).to include(
          "type" => "registered",
          "tunnel_session_id" => session.id,
          "chat_session_id" => nil
        )
      end

      it "reconnects an existing active session instead of creating a duplicate" do
        existing = LocalTunnelSession.create!(
          user: user,
          repo_slug: "acme/old-repo",
          branch: "old-branch",
          status: "paused",
          connected_at: 10.minutes.ago
        )

        subscribe

        perform :receive, { "type" => "register", "repo_slug" => "acme/widget", "branch" => "feature/new" }

        expect(LocalTunnelSession.where(user: user).count).to eq(1)
        existing.reload
        expect(existing.repo_slug).to eq("acme/widget")
        expect(existing.branch).to eq("feature/new")
        expect(existing.status).to eq("connected")
      end

      it "strips blank repo_slug and branch values gracefully" do
        subscribe

        perform :receive, { "type" => "register", "repo_slug" => "  acme/widget  ", "branch" => "  main  " }

        session = LocalTunnelSession.find_by(user: user)
        expect(session.repo_slug).to eq("acme/widget")
        expect(session.branch).to eq("main")
      end
    end

    describe "tool_result message" do
      it "broadcasts the result to the call-specific channel" do
        subscribe

        expect(ActionCable.server).to receive(:broadcast).with(
          "local_tunnel_result:#{user.id}:abc-123",
          { type: "tool_result", call_id: "abc-123", result: { "output" => "hello" } }
        )

        perform :receive, {
          "type" => "tool_result",
          "call_id" => "abc-123",
          "result" => { "output" => "hello" }
        }
      end

      it "ignores tool_result messages without a call_id" do
        subscribe

        expect(ActionCable.server).not_to receive(:broadcast)

        perform :receive, { "type" => "tool_result", "result" => { "output" => "hello" } }
      end
    end

    describe "graceful_disconnect message" do
      it "marks an active session as disconnected and transmits disconnected" do
        session = LocalTunnelSession.create!(
          user: user,
          repo_slug: "acme/widget",
          branch: "main",
          status: "connected",
          connected_at: 5.minutes.ago
        )

        subscribe

        perform :receive, { "type" => "graceful_disconnect" }

        session.reload
        expect(session.status).to eq("disconnected")
        expect(session.disconnected_at).to be_present
        expect(transmissions.last).to include("type" => "disconnected")
      end

      it "does not error when there is no active session" do
        subscribe

        expect { perform :receive, { "type" => "graceful_disconnect" } }.not_to raise_error

        expect(transmissions.last).to include("type" => "disconnected")
      end
    end

    describe "unsubscribe" do
      it "marks a connected session as paused" do
        session = LocalTunnelSession.create!(
          user: user,
          repo_slug: "acme/widget",
          branch: "main",
          status: "connected",
          connected_at: 5.minutes.ago
        )

        subscribe
        unsubscribe

        session.reload
        expect(session.status).to eq("paused")
      end

      it "ignores unsubscribe when there is no connected session" do
        subscribe

        expect { unsubscribe }.not_to raise_error
      end
    end
  end
end
