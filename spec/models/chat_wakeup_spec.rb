require "rails_helper"

RSpec.describe ChatWakeup, type: :model do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  before do
    clear_enqueued_jobs
  end

  it "requires a prompt and fire_at" do
    wakeup = described_class.new(chat_session: chat_session, user: user)

    expect(wakeup).not_to be_valid
    expect(wakeup.errors[:prompt]).to be_present
    expect(wakeup.errors[:fire_at]).to be_present
  end

  it "enqueues the fire job after commit for the requested time" do
    fire_at = 15.minutes.from_now

    expect {
      described_class.create!(
        chat_session: chat_session,
        user: user,
        prompt: "Check job #123 and reschedule if it is still running.",
        fire_at: fire_at
      )
    }.to have_enqueued_job(ChatWakeupFireJob).at(be_within(1.second).of(fire_at)).on_queue("default")
  end
end
