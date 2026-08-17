require "rails_helper"

RSpec.describe PendingActions::PauseLandingQueue do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def pending_action
    chat_session.pending_actions.create!(
      action: "pause_landing_queue",
      requested_by: "agent"
    )
  end

  it "pauses landing for the acting user" do
    action = pending_action

    action.confirm!(user: user)

    expect(action.reload).to be_confirmed
    expect(user.reload.landing_paused).to be(true)
  end

  it "does not enqueue a landing queue processor run" do
    action = pending_action

    expect do
      action.confirm!(user: user)
    end.not_to have_enqueued_job(LandingQueueProcessorJob)
  end
end
