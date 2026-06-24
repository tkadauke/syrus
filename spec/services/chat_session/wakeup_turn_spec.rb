require "rails_helper"

RSpec.describe ChatSession::WakeupTurn do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, title: "Planning") }
  let(:wakeup) do
    ChatWakeup.create!(
      chat_session: chat_session,
      user: user,
      prompt: "Check job #123 and reschedule if it is not done.",
      fire_at: 5.minutes.from_now
    )
  end

  before do
    clear_enqueued_jobs
  end

  it "creates a traceable wakeup message and enqueues the normal chat turn" do
    message = described_class.new(wakeup).run

    expect(message).to have_attributes(role: "user", chat_session: chat_session)
    expect(message.content).to include(
      "text" => "Check job #123 and reschedule if it is not done.",
      "requested_by" => "wakeup",
      "wakeup_id" => wakeup.id
    )
    expect(chat_session.reload.last_message_at).to be_present
    expect(ChatTurnJob).to have_been_enqueued.with(chat_session.id, message.id).on_queue("chat")
  end
end
