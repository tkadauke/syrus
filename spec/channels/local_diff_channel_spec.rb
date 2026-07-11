require "rails_helper"

RSpec.describe LocalDiffChannel, type: :channel do
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

  it "streams from the user's local diff channel key" do
    enable_local_mode

    subscribe

    expect(subscription).to have_stream_from("local_diff:#{user.id}")
  end

  context "with an active subscription and local_mode enabled" do
    before { enable_local_mode }

    describe "on subscribe" do
      it "broadcasts a git_diff tool_call to the tunnel stream when daemon is connected" do
        LocalTunnelSession.create!(
          user: user,
          repo_slug: "acme/widget",
          branch: "main",
          status: "connected",
          connected_at: 5.minutes.ago
        )

        expect(ActionCable.server).to receive(:broadcast).with(
          "local_tunnel:#{user.id}",
          hash_including(type: "tool_call", tool: "git_diff")
        )

        subscribe
      end

      it "transmits not_connected when no daemon session is active" do
        subscribe

        expect(transmissions.last).to include(
          "type" => "diff_result",
          "diff" => nil,
          "mode" => "head",
          "error" => "not_connected"
        )
      end
    end

    describe "receive (refresh request)" do
      it "broadcasts a git_diff tool_call for head mode" do
        LocalTunnelSession.create!(
          user: user,
          repo_slug: "acme/widget",
          branch: "main",
          status: "connected",
          connected_at: 5.minutes.ago
        )

        subscribe

        expect(ActionCable.server).to receive(:broadcast).with(
          "local_tunnel:#{user.id}",
          hash_including(type: "tool_call", tool: "git_diff")
        )

        perform :receive, { "mode" => "head" }
      end

      it "broadcasts a git_diff_staged tool_call for staged mode" do
        LocalTunnelSession.create!(
          user: user,
          repo_slug: "acme/widget",
          branch: "main",
          status: "connected",
          connected_at: 5.minutes.ago
        )

        subscribe

        expect(ActionCable.server).to receive(:broadcast).with(
          "local_tunnel:#{user.id}",
          hash_including(type: "tool_call", tool: "git_diff_staged")
        )

        perform :receive, { "mode" => "staged" }
      end

      it "defaults to head mode for unknown mode values" do
        LocalTunnelSession.create!(
          user: user,
          repo_slug: "acme/widget",
          branch: "main",
          status: "connected",
          connected_at: 5.minutes.ago
        )

        subscribe

        expect(ActionCable.server).to receive(:broadcast).with(
          "local_tunnel:#{user.id}",
          hash_including(type: "tool_call", tool: "git_diff")
        )

        perform :receive, { "mode" => "unknown_mode" }
      end

      it "transmits not_connected when no daemon session is active" do
        subscribe

        perform :receive, { "mode" => "staged" }

        expect(transmissions.last).to include(
          "type" => "diff_result",
          "diff" => nil,
          "mode" => "staged",
          "error" => "not_connected"
        )
      end

      it "ignores paused sessions (not connected)" do
        LocalTunnelSession.create!(
          user: user,
          repo_slug: "acme/widget",
          branch: "main",
          status: "paused",
          connected_at: 10.minutes.ago
        )

        subscribe

        expect(transmissions.last).to include("error" => "not_connected")
      end
    end
  end
end
