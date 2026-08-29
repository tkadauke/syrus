require "rails_helper"

RSpec.describe "API: /api/v1/app/chats/:id/goal", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(user: user, repository: repository, mode: "planning") }

  def parse_body
    JSON.parse(response.body)
  end

  def enable_coding_mode!(enabled: true)
    Feature.find_or_create_by!(slug: "coding_mode") { |feature| feature.category = "Labs"; feature.name = "Coding Mode" }.update!(enabled: enabled)
  end

  before { sign_in_as(user) }

  it "creates and reads an active goal" do
    put "/api/v1/app/chats/#{chat.id}/goal", params: {
      goal: {
        prompt: "Plan the billing launch",
        completion_condition: "The launch plan is ready",
        approval_policy: "manual",
        auto_file_proposals: true
      }
    }

    expect(response).to have_http_status(:ok)
    active_goal = parse_body["active_goal"]
    expect(active_goal).to include(
      "prompt" => "Plan the billing launch",
      "completion_condition" => "The launch plan is ready",
      "status" => "active",
      "approval_policy" => "manual",
      "auto_file_proposals" => true,
      "auto_submit_jobs" => false
    )
    expect(active_goal["mode_snapshot"]).to include("mode" => "planning", "repository_id" => repository.id)

    get "/api/v1/app/chats/#{chat.id}/goal"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("active_goal", "id")).to eq(active_goal["id"])
  end

  it "updates an existing active goal instead of creating a second one" do
    chat.chat_goals.create!(
      prompt: "Old prompt",
      completion_condition: "Original condition",
      approval_policy: "manual",
      auto_file_proposals: true
    )

    patch "/api/v1/app/chats/#{chat.id}/goal", params: { goal: { prompt: "New prompt" } }

    expect(response).to have_http_status(:ok)
    expect(chat.chat_goals.count).to eq(1)
    expect(parse_body["active_goal"]).to include(
      "prompt" => "New prompt",
      "completion_condition" => "Original condition",
      "approval_policy" => "manual",
      "auto_file_proposals" => true
    )
  end

  it "allows partial updates without requiring prompt" do
    chat.chat_goals.create!(prompt: "Old prompt")

    patch "/api/v1/app/chats/#{chat.id}/goal", params: { goal: { completion_condition: "Stop when done." } }

    expect(response).to have_http_status(:ok)
    expect(parse_body["active_goal"]).to include(
      "prompt" => "Old prompt",
      "completion_condition" => "Stop when done."
    )
  end

  it "uses the requested repository in the persisted goal and mode snapshot" do
    other_repository = Factories.repository(user: user, owner: "acme", name: "api")

    put "/api/v1/app/chats/#{chat.id}/goal", params: { goal: { prompt: "Plan API work", repository_id: other_repository.id } }

    expect(response).to have_http_status(:ok)
    expect(parse_body["active_goal"]).to include("repository_id" => other_repository.id)
    expect(parse_body.dig("active_goal", "mode_snapshot", "repository_id")).to eq(other_repository.id)
  end

  it "pauses, resumes, stops, and clears the active goal payload" do
    goal = chat.chat_goals.create!(prompt: "Keep going")

    post "/api/v1/app/chats/#{chat.id}/goal/pause"
    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("active_goal", "status")).to eq("paused")

    post "/api/v1/app/chats/#{chat.id}/goal/resume"
    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("active_goal", "status")).to eq("active")

    post "/api/v1/app/chats/#{chat.id}/goal/stop", params: { reason: "operator_stopped" }
    expect(response).to have_http_status(:ok)
    expect(parse_body["active_goal"]).to be_nil
    expect(goal.reload).to have_attributes(status: "cancelled", terminal_reason: "operator_stopped")
  end

  it "completes and blocks active goals with terminal reasons" do
    complete_goal = chat.chat_goals.create!(prompt: "Finish it")
    post "/api/v1/app/chats/#{chat.id}/goal/complete", params: { reason: "success" }

    expect(response).to have_http_status(:ok)
    expect(complete_goal.reload).to have_attributes(status: "completed", terminal_reason: "success")

    blocked_goal = chat.chat_goals.create!(prompt: "Try again")
    post "/api/v1/app/chats/#{chat.id}/goal/block", params: { reason: "needs_credentials", details: { "provider" => "github" } }

    expect(response).to have_http_status(:ok)
    expect(blocked_goal.reload).to have_attributes(status: "blocked", terminal_reason: "needs_credentials")
    expect(blocked_goal.terminal_details).to eq("provider" => "github")
  end

  it "rejects auto policies that do not match the chat mode" do
    put "/api/v1/app/chats/#{chat.id}/goal", params: { goal: { prompt: "Plan", auto_submit_jobs: true } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
  end

  it "respects coding mode feature gates when starting a coding goal" do
    chat.update!(mode: "coding")
    enable_coding_mode!(enabled: false)

    put "/api/v1/app/chats/#{chat.id}/goal", params: { goal: { prompt: "Implement it", auto_submit_jobs: true } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("feature_disabled")
  end

  it "allows coding goals to auto-submit jobs when coding mode is enabled" do
    chat.update!(mode: "coding")
    enable_coding_mode!

    put "/api/v1/app/chats/#{chat.id}/goal", params: { goal: { prompt: "Implement it", auto_submit_jobs: true } }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("active_goal", "auto_submit_jobs")).to eq(true)
  end

  it "returns active goal JSON in show and index payloads" do
    goal = chat.chat_goals.create!(prompt: "Make progress", auto_file_proposals: true)

    get "/api/v1/app/chats/#{chat.id}"
    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("chat", "active_goal", "id")).to eq(goal.id)
    expect(parse_body.dig("active_goal", "id")).to eq(goal.id)

    get "/api/v1/app/chats"
    expect(response).to have_http_status(:ok)
    serialized = parse_body.fetch("groups").flat_map { |group| group.fetch("chats") }.find { |row| row["id"] == chat.id }
    expect(serialized.dig("active_goal", "id")).to eq(goal.id)
  end

  it "does not expose another user's chat goal" do
    other = Factories.user
    other_chat = ChatSession.create!(user: other, repository: Factories.repository(user: other))

    get "/api/v1/app/chats/#{other_chat.id}/goal"

    expect(response).to have_http_status(:not_found)
  end
end
