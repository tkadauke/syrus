require "rails_helper"

RSpec.describe PendingActions::WakeLandingQueue do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def pending_action(reason: "landing queue looks stuck")
    chat_session.pending_actions.create!(
      action: "wake_landing_queue",
      payload: { "reason" => reason },
      reason: reason,
      requested_by: "operator"
    )
  end

  it "enqueues a landing queue processor run" do
    action = pending_action

    expect do
      action.confirm!(user: user)
    end.to have_enqueued_job(LandingQueueProcessorJob)
    expect(action.reload).to be_confirmed
  end

  it "raises ArgumentError when the acting user is not an admin" do
    user # ensure an earlier user exists so this one isn't auto-promoted as the instance's first admin
    non_admin = Factories.user
    non_admin_chat_session = ChatSession.create!(user: non_admin, repository: Factories.repository(user: non_admin))
    action = non_admin_chat_session.pending_actions.create!(
      action: "wake_landing_queue",
      payload: { "reason" => "landing queue looks stuck" },
      reason: "landing queue looks stuck",
      requested_by: "operator"
    )

    expect { action.confirm!(user: non_admin) }.to raise_error(ArgumentError, /Admin access required/)
  end

  it "is invalid without a reason" do
    action = chat_session.pending_actions.new(
      action: "wake_landing_queue",
      payload: { "reason" => "" },
      requested_by: "operator"
    )

    expect(action).not_to be_valid
    expect(action.errors[:reason]).to be_present
  end
end
