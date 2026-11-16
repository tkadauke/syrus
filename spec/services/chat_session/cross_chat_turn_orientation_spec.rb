require "rails_helper"

RSpec.describe ChatSession::CrossChatTurnOrientation do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }

  def orientation(content:, user_note: "Please take a look", chat_session: chat)
    message = instance_double(ChatMessage, content: content)

    described_class.chat_turn_orientation(
      chat_session: chat_session,
      message: message,
      user_note: user_note
    )
  end

  it "does not claim ordinary messages or messages with non-object content" do
    expect(orientation(content: { "text" => "hello" })).to be_nil
    expect(orientation(content: "hello")).to be_nil
  end

  it "resolves the origin from the bridge thread when the message omits it" do
    origin = ChatSession.create!(user: user, title: "Release planning")
    thread = ChatBridgeThread.create!(
      origin_chat_session: origin,
      target_chat_session: chat,
      opened_by_user: user
    )

    prompt = orientation(content: { "requested_by" => "cross_chat", "thread_id" => thread.id })

    expect(prompt).to include("Origin chat: ##{origin.id} (Release planning)")
    expect(prompt).to include("Bridge thread: ##{thread.id}")
    expect(prompt).to include("call `send_chat_message` with that thread id")
    expect(prompt).not_to include("reply_in_chat_thread")
  end

  it "preserves supplied provenance when the referenced records are unavailable" do
    prompt = orientation(
      content: {
        "requested_by" => "cross_chat",
        "origin_chat_session_id" => 987_654_321,
        "thread_id" => 123_456_789
      }
    )

    expect(prompt).to include("Origin chat: #987654321")
    expect(prompt).to include("Bridge thread: #123456789")
    expect(prompt).to include("call `send_chat_message` with that thread id")
  end

  it "omits reply instructions when no bridge thread is identified" do
    prompt = orientation(
      content: { "requested_by" => "cross_chat" },
      user_note: nil
    )

    expect(prompt).to include("Cross-chat bridge message")
    expect(prompt).to end_with("Message:\n")
    expect(prompt).not_to include("send_chat_message", "reply_in_chat_thread")
  end

  it "uses ordinary-chat instructions when a chat exposes a non-coworker participant" do
    participant = instance_double("Coworkers::Coworker", kind: "assistant")
    chat.define_singleton_method(:coworker) { participant }

    prompt = orientation(
      content: { "requested_by" => "cross_chat", "thread_id" => 123_456_789 }
    )

    expect(prompt).to include("call `send_chat_message` with that thread id")
    expect(prompt).not_to include("reply_in_chat_thread")
  end
end
