require "rails_helper"

RSpec.describe ChatChannel, type: :channel do
  let(:user) { Factories.user }

  before do
    stub_connection current_user: user
  end

  it "rejects subscriptions without a chat id" do
    subscribe

    expect(subscription).to be_rejected
  end

  it "rejects subscriptions for another user's chat" do
    other_chat = ChatSession.create!(user: Factories.user)

    subscribe(chat_id: other_chat.id)

    expect(subscription).to be_rejected
  end

  it "streams from the chat-scoped resource channel for the owner" do
    chat_session = ChatSession.create!(user: user)

    subscribe(chat_id: chat_session.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("chat_resource:#{chat_session.id}")
  end

  it "rejects subscriptions for a soft-deleted chat" do
    chat_session = ChatSession.create!(user: user, deleted_at: Time.current)

    subscribe(chat_id: chat_session.id)

    expect(subscription).to be_rejected
  end

  it "confirms for a group chat participant who isn't the owner" do
    chat_session = ChatSession.create!(user: Factories.user)
    member = Factories.user
    chat_session.chat_participants.create!(user: member, role: "member")

    stub_connection current_user: member
    subscribe(chat_id: chat_session.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("chat_resource:#{chat_session.id}")
  end
end
