require "rails_helper"

RSpec.describe ScheduledChatMessageFireJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, title: "Planning") }

  def create_scheduled_message(sent_at: nil)
    ScheduledChatMessage.create!(
      chat_session: chat_session,
      user: user,
      body: "Check JOB-123 and report back.",
      fire_at: 1.minute.ago,
      sent_at: sent_at
    )
  end

  before do
    clear_enqueued_jobs
  end

  it "creates a traceable user message, marks the row sent, and enqueues a chat turn" do
    scheduled_message = create_scheduled_message

    described_class.perform_now(scheduled_message.id)

    message = chat_session.messages.last
    expect(message).to have_attributes(role: "user")
    expect(message.content).to include(
      "text" => "Check JOB-123 and report back.",
      "requested_by" => "scheduled_message",
      "scheduled_message_id" => scheduled_message.id
    )
    expect(scheduled_message.reload.sent_at).to be_present
    expect(ChatTurnJob).to have_been_enqueued.with(chat_session.id, message.id).on_queue("chat")
  end

  it "does not send an already sent scheduled message twice" do
    scheduled_message = create_scheduled_message(sent_at: Time.current)

    expect {
      described_class.perform_now(scheduled_message.id)
    }.not_to change(ChatMessage, :count)
    expect(ChatTurnJob).not_to have_been_enqueued
  end
end
