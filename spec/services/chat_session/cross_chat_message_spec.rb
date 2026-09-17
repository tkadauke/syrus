require "rails_helper"

RSpec.describe ChatSession::CrossChatMessage do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:origin_chat) { ChatSession.create!(user: user, title: "Origin") }
  let(:target_chat) { ChatSession.create!(user: user, title: "Target") }
  let(:thread) do
    ChatBridgeThread.create!(
      origin_chat_session: origin_chat,
      target_chat_session: target_chat,
      opened_by_user: user,
      max_hops: 2
    )
  end

  before do
    clear_enqueued_jobs
  end

  describe "#deliver!" do
    it "posts an outbound bridge message in the origin chat" do
      described_class.new(thread: thread, text: "check on JOB-1").deliver!

      outbound = origin_chat.messages.order(:id).last
      expect(outbound.role).to eq("system")
      expect(outbound.content).to include(
        "cross_chat_bridge" => "outbound",
        "bridge_thread_id" => thread.id,
        "target_chat_session_id" => target_chat.id
      )
    end

    it "delivers to the target chat via a ChatWakeup with cross_chat metadata" do
      expect {
        described_class.new(thread: thread, text: "check on JOB-1").deliver!
      }.to change { ChatWakeup.count }.by(1)

      wakeup = ChatWakeup.last
      expect(wakeup.chat_session).to eq(target_chat)
      expect(wakeup.user).to eq(target_chat.user)
      expect(wakeup.prompt).to eq("check on JOB-1")
      expect(wakeup.fire_at).to be_within(2.seconds).of(Time.current)
      expect(wakeup.metadata).to include(
        "requested_by" => "cross_chat",
        "origin_chat_session_id" => origin_chat.id,
        "thread_id" => thread.id
      )
    end

    it "increments hop_count on each delivery" do
      expect {
        described_class.new(thread: thread, text: "hop 1").deliver!
      }.to change { thread.reload.hop_count }.from(0).to(1)
    end

    it "auto-closes the thread and posts a system notice to both chats once max_hops is reached" do
      described_class.new(thread: thread, text: "hop 1").deliver!
      described_class.new(thread: thread, text: "hop 2").deliver!

      expect(thread.reload).to be_closed

      [ origin_chat, target_chat ].each do |chat|
        notice = chat.messages.order(:id).last
        expect(notice.role).to eq("system")
        expect(notice.content["text"]).to include("closed")
        expect(notice.content["bridge_thread_id"]).to eq(thread.id)
      end
    end

    it "rejects delivery on a closed thread" do
      thread.close!

      expect {
        described_class.new(thread: thread, text: "too late").deliver!
      }.to raise_error(described_class::ClosedThreadError)

      expect(ChatWakeup.count).to eq(0)
    end
  end
end
