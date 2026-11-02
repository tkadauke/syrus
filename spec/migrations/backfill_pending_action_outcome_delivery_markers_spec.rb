require "rails_helper"
require Rails.root.join("db/migrate/20261102104652_backfill_pending_action_outcome_delivery_markers")

RSpec.describe BackfillPendingActionOutcomeDeliveryMarkers, :ci_only do
  let(:migration) { described_class.new }

  it "is idempotent and marks terminal records left by the previously applied migration" do
    user = Factories.user
    chat = ChatSession.create!(user: user, last_message_at: Time.current)
    action = chat.pending_actions.create!(action: "pause_landing_queue", payload: {})
    action.update_columns(state: "failed", execution_status: "failed", legacy_outcome: false, dismissed_at: nil)
    group = PendingActionGroup.create!(chat_session: chat, user: user)
    group.update_columns(state: "confirmed", legacy_outcome: false, dismissed_at: nil)

    expect { 2.times { migration.up } }.not_to raise_error

    expect(action.reload).to have_attributes(legacy_outcome: true)
    expect(action.dismissed_at).to be_present
    expect(group.reload).to have_attributes(legacy_outcome: true)
    expect(group.dismissed_at).to be_present
  end
end
