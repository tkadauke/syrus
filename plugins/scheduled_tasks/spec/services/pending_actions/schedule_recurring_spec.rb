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

    it "links the created task after confirmation" do
      action = chat_session.pending_actions.create!(
        action_type: "schedule_recurring",
        payload: { "label" => "Nightly rebuild", "cron_expression" => "0 2 * * *", "prompt" => "Rebuild caches." }
      )
      task = ScheduledTasks::Task.create!(user: user, repository: repository, kind: "cron", name: "Nightly rebuild", cron_expression: "0 2 * * *", prompt: "Rebuild caches.")
      action.update!(result: task)

      expect(described_class.new(action).presentation_resource).to eq(
        resource_title: "Nightly rebuild",
        resource_url: "/scheduled_tasks/#{task.id}"
      )
    end
  end

  describe "authorization" do
    let!(:_bootstrap_admin) { Factories.user(admin: true) }

    it "re-checks repository write access when the pending action executes" do
      member = Factories.user
      repo = Factories.repository(user: member)
      session = ChatSession.create!(user: member, repository: repo)
      action = session.pending_actions.create!(
        action_type: "schedule_recurring",
        reason: "Operator asked for a nightly reminder.",
        payload: { "label" => "Nightly rebuild", "cron_expression" => "0 2 * * *", "prompt" => "Rebuild caches." }
      )
      repo.repository_memberships.find_by!(user: member).update!(role: "read")

      expect { described_class.new(action).execute }.to raise_error(ArgumentError, /write access/)
      expect(ScheduledTasks::Task.count).to eq(0)
    end
  end
end
