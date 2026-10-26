require "rails_helper"

RSpec.describe ChatMessage, "mention notifications" do
  let(:sender) { Factories.user(email_address: "sender@example.com") }
  let(:mentioned_user) { Factories.user(email_address: "maya@example.com") }
  let(:chat) do
    ChatSession.create!(user: sender, conversation_kind: "group").tap do |session|
      session.chat_participants.create!(user: mentioned_user, role: "member")
    end
  end

  before { allow(ActionCable.server).to receive(:broadcast) }

  it "creates one durable notification for a mentioned human without triggering a turn" do
    message = nil
    expect {
      message = chat.messages.create!(
        role: "user",
        sender_user: sender,
        content: { "text" => "@maya please review this with @maya" },
        skip_turn_trigger: true
      )
    }.to change { mentioned_user.notifications.where(kind: "chat_mention").count }.by(1)

    notification = mentioned_user.notifications.find_by!(kind: "chat_mention")
    expect(notification).to have_attributes(
      body: "sender mentioned you in a chat.",
      target_path: "/chats/#{chat.id}#message-#{message.id}"
    )
    expect(chat.reload).not_to be_turn_in_flight
  end

  it "does not notify the sender for mentioning their own handle" do
    expect {
      chat.messages.create!(
        role: "user",
        sender_user: sender,
        content: { "text" => "note to @sender" },
        skip_turn_trigger: true
      )
    }.not_to change { sender.notifications.where(kind: "chat_mention").count }
  end

  it "does not notify a human who is not in the chat" do
    outsider = Factories.user(email_address: "outsider@example.com")

    expect {
      chat.messages.create!(
        role: "user",
        sender_user: sender,
        content: { "text" => "hello @outsider" },
        skip_turn_trigger: true
      )
    }.not_to change { outsider.notifications.where(kind: "chat_mention").count }
  end
end
