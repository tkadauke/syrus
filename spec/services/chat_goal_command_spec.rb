require "rails_helper"

RSpec.describe ChatGoalCommand, type: :service do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, repository: repository, mode: "planning") }

  before { clear_enqueued_jobs }

  it "parses supported goal slash commands" do
    expect(described_class.parse("/goal ship billing")).to eq(action: "start", args: "ship billing")
    expect(described_class.parse("/goal pause")).to eq(action: "pause", args: "")
    expect(described_class.parse("/goal resume")).to eq(action: "resume", args: "")
    expect(described_class.parse("/goal stop")).to eq(action: "stop", args: "")
    expect(described_class.parse("/goal edit new target")).to eq(action: "edit", args: "new target")
    expect(described_class.parse("/goals nope")).to be_nil
  end

  it "starts, edits, pauses, resumes, and stops a goal" do
    command = described_class.new(chat_session: chat, user: user)

    expect(command.call("/goal plan launch").goal).to be_active
    expect(chat.reload.active_goal.prompt).to eq("plan launch")

    command.call("/goal edit plan launch safely")
    expect(chat.reload.active_goal.prompt).to eq("plan launch safely")

    command.call("/goal pause")
    expect(chat.reload.active_goal).to be_paused

    command.call("/goal resume")
    expect(chat.reload.active_goal).to be_active

    command.call("/goal stop")
    expect(chat.reload.active_goal).to be_nil
    expect(chat.chat_goals.last).to be_cancelled
  end

  it "starts a goal with an immediate continuation turn" do
    command = described_class.new(chat_session: chat, user: user)
    goal_id = nil

    expect {
      result = command.call("/goal plan launch")
      expect(result.goal).to be_active
      goal_id = result.goal.id
    }.to change(ChatMessage, :count).by(1)

    message = chat.messages.last
    expect(message.content).to include(
      "source" => "goal_continuation",
      "goal_continuation" => true,
      "chat_goal_id" => goal_id
    )
    expect(chat.scoped_events.last).to have_attributes(source_kind: "goal_started")
    expect(ChatTurnJob).to have_been_enqueued.with(chat.id, message.id)
  end

  it "does not enqueue another continuation when start edits an already-active goal" do
    command = described_class.new(chat_session: chat, user: user)
    command.call("/goal plan launch")
    clear_enqueued_jobs

    expect {
      command.call("/goal plan launch safely")
    }.not_to change(ChatMessage, :count)

    expect(chat.reload.active_goal.prompt).to eq("plan launch safely")
    expect(ChatTurnJob).not_to have_been_enqueued
  end

  it "wakes the chat when start resumes a paused goal" do
    command = described_class.new(chat_session: chat, user: user)
    goal = chat.chat_goals.create!(user: user, prompt: "old plan")
    goal.pause!

    expect {
      command.call("/goal new plan")
    }.to change(ChatMessage, :count).by(1)

    expect(goal.reload).to be_active
    expect(chat.scoped_events.last).to have_attributes(source_kind: "goal_started")
    expect(ChatTurnJob).to have_been_enqueued.with(chat.id, chat.messages.last.id)
  end
end
