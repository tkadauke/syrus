require "rails_helper"

RSpec.describe Mcp::Tools::SendChatMessageTool do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:origin_chat) { ChatSession.create!(user: user, title: "Origin") }
  let(:target_chat) { ChatSession.create!(user: user, title: "Target") }
  let(:other_user_chat) { ChatSession.create!(user: other_user, title: "Other user's chat") }

  before { clear_enqueued_jobs }

  def operator_message(chat_session, text: "hi")
    chat_session.messages.create!(role: "user", content: { "text" => text }, sender_user_id: chat_session.user_id)
  end

  def automated_message(chat_session, requested_by: "wakeup")
    chat_session.messages.create!(role: "user", content: { "text" => "auto", "requested_by" => requested_by })
  end

  def call(chat_session:, current_message:, **arguments)
    described_class.call(server_context: { chat_session: chat_session, current_message: current_message }, **arguments)
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  describe "opening a new thread" do
    it "opens a ChatBridgeThread and wakes the target chat when the operator's own message triggered this turn" do
      message = operator_message(origin_chat)

      response = call(chat_session: origin_chat, current_message: message, text: "check on JOB-1", target_chat_session_id: target_chat.id)

      expect(response.error?).to be_falsey
      thread = ChatBridgeThread.sole
      expect(thread).to have_attributes(
        origin_chat_session_id: origin_chat.id,
        target_chat_session_id: target_chat.id,
        opened_by_user_id: user.id,
        state: "open",
        hop_count: 1
      )
      body = payload(response)
      expect(body).to include(thread_id: thread.id, state: "open", hop_count: 1, max_hops: ChatBridgeThread::DEFAULT_MAX_HOPS, target_chat_session_id: target_chat.id)

      wakeup = ChatWakeup.sole
      expect(wakeup.chat_session).to eq(target_chat)
      expect(wakeup.prompt).to eq("check on JOB-1")
      expect(wakeup.metadata).to include("requested_by" => "cross_chat", "thread_id" => thread.id)
    end

    it "honors a custom max_hops" do
      message = operator_message(origin_chat)

      call(chat_session: origin_chat, current_message: message, text: "hi", target_chat_session_id: target_chat.id, max_hops: 2)

      expect(ChatBridgeThread.sole.max_hops).to eq(2)
    end

    it "rejects opening a new thread from an automated/system-originated turn" do
      message = automated_message(origin_chat, requested_by: "wakeup")

      response = call(chat_session: origin_chat, current_message: message, text: "hi", target_chat_session_id: target_chat.id)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("operator's own message")
      expect(ChatBridgeThread.count).to eq(0)
      expect(ChatWakeup.count).to eq(0)
    end

    it "rejects opening a new thread from a cross-chat-delivered turn" do
      message = automated_message(origin_chat, requested_by: "cross_chat")

      response = call(chat_session: origin_chat, current_message: message, text: "hi", target_chat_session_id: target_chat.id)

      expect(response).to be_error
      expect(ChatBridgeThread.count).to eq(0)
    end

    it "rejects opening a new thread when there is no current message" do
      response = call(chat_session: origin_chat, current_message: nil, text: "hi", target_chat_session_id: target_chat.id)

      expect(response).to be_error
      expect(ChatBridgeThread.count).to eq(0)
    end

    it "rejects a target chat session not owned by the same operator" do
      message = operator_message(origin_chat)

      response = call(chat_session: origin_chat, current_message: message, text: "hi", target_chat_session_id: other_user_chat.id)

      expect(response).to be_error
      expect(payload(response)).to eq(error: "not_authorized")
      expect(ChatBridgeThread.count).to eq(0)
    end

    it "rejects opening a bridge thread to the same chat" do
      message = operator_message(origin_chat)

      response = call(chat_session: origin_chat, current_message: message, text: "hi", target_chat_session_id: origin_chat.id)

      expect(response).to be_error
      expect(ChatBridgeThread.count).to eq(0)
    end
  end

  describe "replying within an existing thread" do
    let(:thread) do
      ChatBridgeThread.create!(origin_chat_session: origin_chat, target_chat_session: target_chat, opened_by_user: user, max_hops: 3)
    end

    it "delivers a reply from the origin chat" do
      message = operator_message(origin_chat)

      response = call(chat_session: origin_chat, current_message: message, text: "hop 1", thread_id: thread.id)

      expect(response.error?).to be_falsey
      expect(thread.reload.hop_count).to eq(1)
      wakeup = ChatWakeup.sole
      expect(wakeup.chat_session).to eq(target_chat)
    end

    it "delivers a reply from the target chat back to the origin chat, even from an automated turn" do
      message = automated_message(target_chat, requested_by: "cross_chat")

      response = call(chat_session: target_chat, current_message: message, text: "reply", thread_id: thread.id)

      expect(response.error?).to be_falsey
      wakeup = ChatWakeup.sole
      expect(wakeup.chat_session).to eq(origin_chat)
      expect(payload(response)).to include(target_chat_session_id: origin_chat.id)
    end

    it "auto-closes the thread once max_hops is reached and reflects that in the payload" do
      operator = operator_message(origin_chat)
      call(chat_session: origin_chat, current_message: operator, text: "hop 1", thread_id: thread.id)
      call(chat_session: target_chat, current_message: operator_message(target_chat), text: "hop 2", thread_id: thread.id)

      response = call(chat_session: origin_chat, current_message: operator_message(origin_chat), text: "hop 3", thread_id: thread.id)

      expect(payload(response)).to include(state: "closed", hop_count: 3, max_hops: 3)
      expect(thread.reload).to be_closed
    end

    it "rejects replying on a closed thread" do
      thread.close!
      message = operator_message(origin_chat)

      response = call(chat_session: origin_chat, current_message: message, text: "too late", thread_id: thread.id)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("closed")
      expect(ChatWakeup.count).to eq(0)
    end

    it "rejects a thread the calling chat is not a member of" do
      bystander_chat = ChatSession.create!(user: user, title: "Bystander")
      message = operator_message(bystander_chat)

      response = call(chat_session: bystander_chat, current_message: message, text: "hi", thread_id: thread.id)

      expect(response).to be_error
      expect(payload(response)).to eq(error: "not_authorized")
    end

    it "rejects an unknown thread id" do
      message = operator_message(origin_chat)

      response = call(chat_session: origin_chat, current_message: message, text: "hi", thread_id: ChatBridgeThread.maximum(:id).to_i + 100)

      expect(response).to be_error
      expect(payload(response)).to eq(error: "not_authorized")
    end
  end

  describe "input validation" do
    it "rejects blank text" do
      message = operator_message(origin_chat)

      response = call(chat_session: origin_chat, current_message: message, text: "  ", target_chat_session_id: target_chat.id)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("text is required")
    end

    it "rejects supplying both thread_id and target_chat_session_id" do
      thread = ChatBridgeThread.create!(origin_chat_session: origin_chat, target_chat_session: target_chat, opened_by_user: user)
      message = operator_message(origin_chat)

      response = call(chat_session: origin_chat, current_message: message, text: "hi", thread_id: thread.id, target_chat_session_id: target_chat.id)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("exactly one of")
    end

    it "rejects supplying neither thread_id nor target_chat_session_id" do
      message = operator_message(origin_chat)

      response = call(chat_session: origin_chat, current_message: message, text: "hi")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("exactly one of")
    end
  end
end
