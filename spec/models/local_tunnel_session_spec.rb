require "rails_helper"

RSpec.describe LocalTunnelSession, type: :model do
  let(:user) { Factories.user }

  def connected_session
    described_class.create!(user: user, status: "connected", connected_at: Time.current)
  end

  it "defaults to connected status" do
    session = described_class.create!(user: user)
    expect(session.status).to eq("connected")
  end

  it "accepts all known statuses" do
    LocalTunnelSession::STATUSES.each do |status|
      session = described_class.new(user: user, status: status)
      expect(session).to be_valid
    end
  end

  it "rejects unknown statuses" do
    session = described_class.new(user: user, status: "idle")
    expect(session).not_to be_valid
  end

  describe ".active scope" do
    it "includes connected and paused sessions" do
      s1 = described_class.create!(user: user, status: "connected")
      s2 = described_class.create!(user: user, status: "paused")
      s3 = described_class.create!(user: user, status: "disconnected")

      active = described_class.active
      expect(active).to include(s1, s2)
      expect(active).not_to include(s3)
    end
  end

  describe ".connected scope" do
    it "includes only connected sessions" do
      s1 = described_class.create!(user: user, status: "connected")
      s2 = described_class.create!(user: user, status: "paused")

      expect(described_class.connected).to include(s1)
      expect(described_class.connected).not_to include(s2)
    end
  end

  describe "#disconnect!" do
    it "sets status to disconnected and stamps disconnected_at" do
      session = connected_session

      freeze_time do
        session.disconnect!

        expect(session.status).to eq("disconnected")
        expect(session.disconnected_at).to be_within(1.second).of(Time.current)
      end
    end
  end

  describe "#pause!" do
    it "sets status to paused" do
      session = connected_session

      session.pause!

      expect(session.status).to eq("paused")
    end
  end

  describe "#reconnect!" do
    it "sets status back to connected and updates repo slug, branch, and timestamps" do
      session = connected_session
      session.disconnect!

      freeze_time do
        session.reconnect!(repo_slug: "acme/widgets", branch: "feat-123")

        expect(session.status).to eq("connected")
        expect(session.repo_slug).to eq("acme/widgets")
        expect(session.branch).to eq("feat-123")
        expect(session.connected_at).to be_within(1.second).of(Time.current)
        expect(session.disconnected_at).to be_nil
      end
    end
  end
end
