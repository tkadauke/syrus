require "rails_helper"

RSpec.describe ScheduledChatMessageFireJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, title: "Planning") }

  def create_scheduled_message(chat: chat_session, body: "Check JOB-123 and report back.", sent_at: nil)
    ScheduledChatMessage.create!(
      chat_session: chat,
      user: user,
      body: body,
      fire_at: 1.minute.ago,
      sent_at: sent_at
    )
  end

  def create_group_chat
    ChatSession.create!(user: user, title: "Planning", conversation_kind: "group").tap do |chat|
      chat.chat_participants.create!(user: Factories.user, role: "member")
    end
  end

  before do
    clear_enqueued_jobs
  end

  it "creates a traceable user message, marks the row sent, and enqueues a chat turn" do
    scheduled_message = create_scheduled_message

    described_class.perform_now(scheduled_message.id)

    message = chat_session.messages.last
    expect(message).to have_attributes(role: "user", sender_user_id: user.id)
    expect(message.content).to include(
      "text" => "Check JOB-123 and report back.",
      "requested_by" => "scheduled_message",
      "scheduled_message_id" => scheduled_message.id
    )
    expect(scheduled_message.reload.sent_at).to be_present
    expect(ChatTurnJob).to have_been_enqueued.with(chat_session.id, message.id).on_queue("chat")
  end

  it "does not trigger the agent for an unmentioned scheduled message in a group chat" do
    group_chat = create_group_chat
    scheduled_message = create_scheduled_message(chat: group_chat, body: "Posting an FYI for the team.")

    described_class.perform_now(scheduled_message.id)

    message = group_chat.messages.last
    expect(message).to have_attributes(role: "user", sender_user_id: user.id)
    expect(message.content).to include(
      "text" => "Posting an FYI for the team.",
      "requested_by" => "scheduled_message",
      "scheduled_message_id" => scheduled_message.id
    )
    expect(group_chat.reload).not_to be_turn_in_flight
    expect(ChatTurnJob).not_to have_been_enqueued
  end

  it "triggers the agent for a mentioned scheduled message in a group chat" do
    group_chat = create_group_chat
    scheduled_message = create_scheduled_message(chat: group_chat, body: "@syrus summarize this for us.")

    described_class.perform_now(scheduled_message.id)

    message = group_chat.messages.last
    expect(group_chat.reload).to be_turn_in_flight
    expect(ChatTurnJob).to have_been_enqueued.with(group_chat.id, message.id).on_queue("chat")
  end

  it "queues a scheduled message instead of inserting it during an active turn" do
    chat_session.messages.create!(role: "user", content: { "text" => "First turn" }, sender_user: user)
    scheduled_message = create_scheduled_message(body: "Follow-up after the turn.")

    expect {
      described_class.perform_now(scheduled_message.id)
    }.not_to change(ChatMessage, :count)

    queued_message = chat_session.chat_queued_messages.last
    expect(queued_message.content).to include(
      "text" => "Follow-up after the turn.",
      "requested_by" => "scheduled_message",
      "scheduled_message_id" => scheduled_message.id,
      ChatQueuedMessage::INTERNAL_SENDER_USER_ID_KEY => user.id
    )
    expect(scheduled_message.reload.sent_at).to be_present
    expect(ChatTurnJob).not_to have_been_enqueued
  end

  it "queues a scheduled message while the agent process is busy" do
    allow_any_instance_of(ChatSession).to receive(:agent_busy?).and_return(true)
    scheduled_message = create_scheduled_message(body: "Wait until the current work settles.")
    message_count = ChatMessage.count

    expect {
      described_class.perform_now(scheduled_message.id)
    }.to change(ChatQueuedMessage, :count).by(1)

    expect(ChatMessage.count).to eq(message_count)
    expect(ChatTurnJob).not_to have_been_enqueued
  end

  it "does not send an already sent scheduled message twice" do
    scheduled_message = create_scheduled_message(sent_at: Time.current)

    expect {
      described_class.perform_now(scheduled_message.id)
    }.not_to change(ChatMessage, :count)
    expect(ChatTurnJob).not_to have_been_enqueued
  end
end
