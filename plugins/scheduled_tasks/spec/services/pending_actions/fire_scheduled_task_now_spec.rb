require "rails_helper"

RSpec.describe PendingActions::FireScheduledTaskNow do
  describe "#presentation_label" do
    it "labels the action by scheduled_task_id" do
      action = ChatPendingAction.new(action: "fire_scheduled_task_now", payload: { "scheduled_task_id" => 42 })

      expect(described_class.new(action).presentation_label).to eq("Fire scheduled task #42")
    end
  end
end
