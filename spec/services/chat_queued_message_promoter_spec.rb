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

    it "promotes goal continuations as system messages while still triggering a turn" do
      chat.chat_queued_messages.create!(
        content: {
          "text" => "Goal continuation started.",
          "internal_prompt" => "Continue with private goal context.",
          "source" => "goal_continuation",
          "goal_continuation" => true
        }
      )

      expect {
        result = described_class.deliver_one_if_idle!(chat)
        expect(result).to be true
      }.to have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

      message = ChatMessage.where(chat_session: chat).last
      expect(message).to have_attributes(role: "system")
      expect(message.content).to include(
        "text" => "Goal continuation started.",
        "internal_prompt" => "Continue with private goal context.",
        "source" => "goal_continuation"
      )
      expect(chat.reload).to be_turn_in_flight
    end

    it "triggers goal continuations even in group chats without an explicit mention" do
      group_chat = ChatSession.create!(user: user, conversation_kind: "group")
      group_chat.chat_participants.create!(user: Factories.user, role: "member")
      group_chat.chat_queued_messages.create!(
        content: {
          "text" => "Goal continuation started.",
          "internal_prompt" => "Continue with private goal context.",
          "source" => "goal_continuation",
          "goal_continuation" => true
        }
      )

      expect {
        described_class.deliver_one_if_idle!(group_chat)
      }.to have_enqueued_job(ChatTurnJob)

      expect(ChatMessage.where(chat_session: group_chat).last.role).to eq("system")
    end

    it "preserves attachments when promoting a queued message" do
      attachment = { "name" => "shot.png", "mime_type" => "image/png", "data" => "abc123" }
      chat.chat_queued_messages.create!(content: { "text" => "", "attachments" => [ attachment ] })

      result = described_class.deliver_one_if_idle!(chat)

      expect(result).to be true
      message = ChatMessage.where(chat_session: chat).last
      expect(message.content).to include("text" => "", "attachments" => [ attachment ])
    end

    it "promotes deferred system messages with their system role" do
      chat.chat_queued_messages.create!(
        content: {
          "_role" => "system",
          "text" => "Proposal rejected. \"Clean up\" was discarded.",
          "source" => "proposal_notification",
          "acknowledgment" => "Rejected proposal cleanup."
        }
      )

      expect {
        expect(described_class.deliver_one_if_idle!(chat)).to be true
      }.to have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

      message = ChatMessage.where(chat_session: chat).last
      expect(message.role).to eq("system")
      expect(message.sender_user).to be_nil
      expect(message.content).to eq(
        "text" => "Proposal rejected. \"Clean up\" was discarded.",
        "source" => "proposal_notification",
        "acknowledgment" => "Rejected proposal cleanup."
      )
      expect(chat.reload).to be_turn_in_flight
    end

    it "does not expose deferred system messages as editable queued drafts" do
      chat.chat_queued_messages.create!(
        content: {
          "_role" => "system",
          "text" => "Proposal rejected. \"Clean up\" was discarded.",
          "source" => "proposal_notification"
        }
      )

      expect(chat.reload.queued_messages_payload).to eq([])
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

    context "with a group chat" do
      let(:chat) { ChatSession.create!(user: user, conversation_kind: "group") }

      before { chat.chat_participants.create!(user: Factories.user, role: "member") }

      it "promotes but does not trigger the agent for an unmentioned queued message" do
        enqueue_message("no mention here")

        result = nil
        expect {
          result = described_class.deliver_one_if_idle!(chat)
        }.not_to have_enqueued_job(ChatTurnJob)

        expect(result).to be true
        expect(ChatMessage.where(chat_session: chat).count).to eq(1)
        expect(chat.reload).not_to be_turn_in_flight
      end

      it "triggers the agent for a queued message that mentions @syrus" do
        enqueue_message("hey @syrus")

        expect {
          described_class.deliver_one_if_idle!(chat)
        }.to have_enqueued_job(ChatTurnJob)
      end
    end
  end
end
