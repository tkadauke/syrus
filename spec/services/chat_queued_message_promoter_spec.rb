require "rails_helper"

RSpec.describe ChatQueuedMessagePromoter do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }

  def enqueue_message(text = "Hello")
    chat.chat_queued_messages.create!(content: { "text" => text })
  end

  describe "#deliver_one_if_idle!" do
    it "returns false and does nothing when stop has been requested" do
      chat.update!(stop_requested_at: Time.current)
      enqueue_message

      result = described_class.deliver_one_if_idle!(chat)

      expect(result).to be false
      expect(ChatMessage.where(chat_session: chat).count).to eq(0)
    end

    it "returns false when a turn is already in flight" do
      user_msg = chat.messages.create!(role: "user", content: { "text" => "first" })
      enqueue_message("second")

      result = described_class.deliver_one_if_idle!(chat)

      expect(result).to be false
      expect(ChatMessage.where(chat_session: chat).count).to eq(1)
    end

    it "returns false when the agent is busy" do
      allow_any_instance_of(ChatSession).to receive(:agent_busy?).and_return(true)
      enqueue_message

      result = described_class.deliver_one_if_idle!(chat)

      expect(result).to be false
    end

    it "returns false when there are no queued messages" do
      result = described_class.deliver_one_if_idle!(chat)

      expect(result).to be false
    end

    it "promotes the oldest queued message when the session is idle" do
      enqueue_message("pending message")

      result = described_class.deliver_one_if_idle!(chat)

      expect(result).to be true
      message = ChatMessage.where(chat_session: chat).last
      expect(message.role).to eq("user")
      expect(message.content["text"]).to eq("pending message")
    end

    it "marks the queued message as delivered after promotion" do
      queued = enqueue_message("deliver me")

      described_class.deliver_one_if_idle!(chat)

      queued.reload
      expect(queued.delivered_at).not_to be_nil
    end

    it "enqueues a ChatTurnJob after promoting the message" do
      enqueue_message

      expect {
        described_class.deliver_one_if_idle!(chat)
      }.to have_enqueued_job(ChatTurnJob)
    end

    it "promotes only one message per call even when multiple are queued" do
      enqueue_message("first")
      enqueue_message("second")

      described_class.deliver_one_if_idle!(chat)

      expect(ChatMessage.where(chat_session: chat).count).to eq(1)
      expect(ChatMessage.where(chat_session: chat).first.content["text"]).to eq("first")
    end

    it "promotes messages in FIFO order" do
      first = enqueue_message("alpha")
      second = enqueue_message("beta")

      described_class.deliver_one_if_idle!(chat)

      promoted = ChatMessage.where(chat_session: chat).first
      expect(promoted.content["text"]).to eq("alpha")
    end
  end
end
