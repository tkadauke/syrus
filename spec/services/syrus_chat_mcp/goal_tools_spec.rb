require "rails_helper"

RSpec.describe "goal MCP tools" do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }
  let(:server_context) { { chat_session: chat } }

  it "lets the agent complete the active goal" do
    goal = chat.chat_goals.create!(prompt: "Finish the plan")

    response = Mcp::Tools::MarkGoalCompletedTool.call(
      reason: "plan_is_ready",
      server_context: server_context
    )

    expect(response).not_to be_error
    expect(goal.reload).to have_attributes(status: "completed", terminal_reason: "plan_is_ready")
    expect(chat.messages.last.content).to include("source" => "goal_loop", "chat_goal_id" => goal.id)
  end

  it "reloads a memoized active goal before checking active state" do
    goal = chat.chat_goals.create!(prompt: "Finish the plan", status: "paused")
    expect(chat.active_goal).to be_paused
    ChatGoal.where(id: goal.id).update_all(status: "active", updated_at: Time.current)

    response = Mcp::Tools::MarkGoalCompletedTool.call(
      reason: "plan_is_ready",
      server_context: server_context
    )

    expect(response).not_to be_error
    expect(goal.reload).to have_attributes(status: "completed", terminal_reason: "plan_is_ready")
  end

  it "lets the agent block the active goal with a reason" do
    goal = chat.chat_goals.create!(prompt: "Finish the plan")

    response = Mcp::Tools::MarkGoalBlockedTool.call(
      reason: "waiting_for_credentials",
      details: { "provider" => "github" },
      server_context: server_context
    )

    expect(response).not_to be_error
    expect(goal.reload).to have_attributes(status: "blocked", terminal_reason: "waiting_for_credentials")
    expect(goal.terminal_details).to eq("provider" => "github")
  end

  it "rejects blocked results without a reason" do
    chat.chat_goals.create!(prompt: "Finish the plan")

    response = Mcp::Tools::MarkGoalBlockedTool.call(reason: " ", server_context: server_context)

    expect(response).to be_error
  end
end
