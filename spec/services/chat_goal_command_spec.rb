require "rails_helper"

RSpec.describe ChatGoalCommand, type: :service do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, repository: repository, mode: "planning") }

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
end
