require "rails_helper"

RSpec.describe PendingActionOutcomeDeliveryJob do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user, last_message_at: Time.current) }

  it "retries a terminal action whose wake was not enqueued" do
    action = chat.pending_actions.create!(action: "pause_landing_queue", payload: {})
    action.update_columns(state: "failed", execution_status: "failed", execution_error: "queue was unavailable")

    expect { described_class.perform_now }.to have_enqueued_job(ChatTurnJob).once
    expect(action.reload.outcome_message).to be_present
    expect(action.outcome_wake_enqueued_at).to be_present
  end

  it "does not wake the chat for legacy terminal records" do
    action = chat.pending_actions.create!(action: "pause_landing_queue", payload: {})
    action.update_columns(state: "failed", execution_status: "failed", legacy_outcome: true)

    expect { described_class.perform_now }.not_to have_enqueued_job(ChatTurnJob)
    expect(action.reload.outcome_message).to be_nil
  end
end
