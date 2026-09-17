require "rails_helper"

RSpec.describe ChatBridgeThread do
  let(:user) { Factories.user }
  let(:origin_chat) { ChatSession.create!(user: user, title: "Origin") }
  let(:target_chat) { ChatSession.create!(user: user, title: "Target") }

  def build_thread(**attrs)
    described_class.new({
      origin_chat_session: origin_chat,
      target_chat_session: target_chat,
      opened_by_user: user
    }.merge(attrs))
  end

  it "defaults to open state with the DB-level max_hops default" do
    thread = build_thread
    thread.save!

    expect(thread.state).to eq("open")
    expect(thread).to be_open
    expect(thread.hop_count).to eq(0)
    expect(thread.max_hops).to eq(described_class::DEFAULT_MAX_HOPS)
  end

  it "rejects a target chat session owned by a different user" do
    other_user_chat = ChatSession.create!(user: Factories.user, title: "Other")
    thread = build_thread(target_chat_session: other_user_chat)

    expect(thread).not_to be_valid
    expect(thread.errors[:target_chat_session]).to be_present
  end

  it "rejects an invalid state" do
    thread = build_thread(state: "paused")

    expect(thread).not_to be_valid
    expect(thread.errors[:state]).to be_present
  end

  describe "#register_hop!" do
    it "increments hop_count without closing when under max_hops" do
      thread = build_thread(max_hops: 3).tap(&:save!)

      thread.register_hop!

      expect(thread.hop_count).to eq(1)
      expect(thread).to be_open
    end

    it "auto-closes once hop_count reaches max_hops" do
      thread = build_thread(max_hops: 2, hop_count: 1).tap(&:save!)

      thread.register_hop!

      expect(thread.hop_count).to eq(2)
      expect(thread).to be_closed
    end
  end

  describe "#counterpart" do
    it "returns the target chat when given the origin chat" do
      thread = build_thread.tap(&:save!)

      expect(thread.counterpart(origin_chat)).to eq(target_chat)
    end

    it "returns the origin chat when given the target chat" do
      thread = build_thread.tap(&:save!)

      expect(thread.counterpart(target_chat)).to eq(origin_chat)
    end
  end
end
