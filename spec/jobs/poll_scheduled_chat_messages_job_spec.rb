require "rails_helper"

RSpec.describe PollScheduledChatMessagesJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, title: "Planning") }

  def create_scheduled_message(fire_at:, sent_at: nil)
    ScheduledChatMessage.create!(
      chat_session: chat_session,
      user: user,
      body: "Check JOB-123.",
      fire_at: fire_at,
      sent_at: sent_at
    )
  end

  before do
    clear_enqueued_jobs
  end

  it "enqueues due unsent scheduled messages" do
    due = create_scheduled_message(fire_at: 1.minute.ago)
    create_scheduled_message(fire_at: 1.minute.from_now)
    create_scheduled_message(fire_at: 1.minute.ago, sent_at: Time.current)
    clear_enqueued_jobs

    described_class.perform_now

    expect(ScheduledChatMessageFireJob).to have_been_enqueued.with(due.id).once
  end
end
