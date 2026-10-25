require "rails_helper"

RSpec.describe PendingActions::FireScheduledTaskNow do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, repository: repository) }

  describe "#presentation_label" do
    it "labels the action by scheduled_task_id" do
      action = ChatPendingAction.new(action: "fire_scheduled_task_now", payload: { "scheduled_task_id" => 42 })

      expect(described_class.new(action).presentation_label).to eq("Fire scheduled task #42")
    end
  end

  describe "#execute" do
    let(:task) { instance_double(ScheduledTasks::Task, id: 42, repository: repository, archived?: false, fired?: false) }
    let(:action) do
      chat.pending_actions.create!(action: "fire_scheduled_task_now", payload: { "scheduled_task_id" => 42 })
    end
    let(:command) { described_class.new(action) }

    before do
      allow(command).to receive(:scheduled_task).and_return(task)
      allow(command).to receive(:authorize_execution!)
    end

    it "persists a fired outcome and returns the created Job for the pending-action result" do
      job = Factories.job(repository: repository, user: user, issue_title: "Scheduled run")
      result = ScheduledTasks::Fire::Result.new(job: job, skipped: false, reason: nil)
      allow(ScheduledTasks::Fire).to receive(:new).with(task).and_return(instance_double(ScheduledTasks::Fire, call: result))

      expect(command.execute).to eq(job)

      expect(action.reload.payload.fetch("fire_outcome")).to eq("fired" => true, "job_id" => job.id)
      expect(command.tool_card_outcome).to eq(fired: true, job_id: job.id)
    end

    it "persists the reason when a confirmed fire is skipped" do
      result = ScheduledTasks::Fire::Result.new(job: nil, skipped: true, reason: "already_fired_window")
      allow(ScheduledTasks::Fire).to receive(:new).with(task).and_return(instance_double(ScheduledTasks::Fire, call: result))

      expect(command.execute).to be_nil

      expect(action.reload.payload.fetch("fire_outcome")).to eq("fired" => false, "reason" => "already_fired_window")
      expect(command.tool_card_outcome).to eq(fired: false, reason: "already_fired_window")
    end
  end

  describe "presentation" do
    it "exposes the persisted Job to the live card serializer" do
      job = Factories.job(repository: repository, user: user, issue_title: "Scheduled run")
      action = chat.pending_actions.create!(
        action: "fire_scheduled_task_now",
        state: "confirmed",
        payload: { "scheduled_task_id" => 42, "fire_outcome" => { "fired" => true, "job_id" => job.id } },
        result: job
      )
      message = chat.messages.create!(role: "tool_use", tool_name: "fire_scheduled_task_now", pending_action: action, content: {})

      pending_action = App::ChatMessagePayload.messages([ message ], repository: repository).sole.fetch(:pending_action)

      expect(pending_action).to include(
        outcome: { fired: true, job_id: job.id },
        resource_title: "Scheduled run",
        resource_url: "/jobs/#{job.id}"
      )
    end
  end
end
