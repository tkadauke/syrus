require "rails_helper"

RSpec.describe PendingActions::ResumeLandingQueue do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(landing_paused: true) }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def pending_action
    chat_session.pending_actions.create!(
      action: "resume_landing_queue",
      requested_by: "agent"
    )
  end

  it "resumes landing for the acting user" do
    action = pending_action

    action.confirm!(user: user)

    expect(action.reload).to be_confirmed
    expect(user.reload.landing_paused).to be(false)
  end

  it "enqueues a landing queue processor run" do
    action = pending_action

    expect do
      action.confirm!(user: user)
    end.to have_enqueued_job(LandingQueueProcessorJob)
  end
end
