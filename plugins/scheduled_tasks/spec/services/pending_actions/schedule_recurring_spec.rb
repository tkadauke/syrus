require "rails_helper"

RSpec.describe PendingActions::ScheduleRecurring do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  describe "presentation" do
    it "labels and details a schedule_recurring action_type action from its own action_type presentation methods" do
      action = chat_session.pending_actions.create!(
        action_type: "schedule_recurring",
        reason: "Operator asked for a nightly reminder.",
        payload: { "label" => "Nightly rebuild", "cron_expression" => "0 2 * * *", "prompt" => "Rebuild caches." }
      )
      presenter = described_class.new(action)

      expect(presenter.presentation_label).to eq("Nightly rebuild")
      expect(presenter.presentation_detail).to eq("Nightly rebuild — 0 2 * * *\n\nRebuild caches.")
    end

    it "falls back to a humanized action_type when no label is supplied" do
      action = ChatPendingAction.new(action_type: "schedule_recurring", payload: {})

      expect(described_class.new(action).presentation_label).to eq("Schedule recurring")
    end
  end
end
