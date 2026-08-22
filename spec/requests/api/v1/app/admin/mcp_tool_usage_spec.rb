require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/mcp_tool_usage", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:non_admin) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  it "requires an admin user" do
    get "/api/v1/app/admin/mcp_tool_usage"
    expect(response).to have_http_status(:unauthorized)

    sign_in_as(non_admin)
    get "/api/v1/app/admin/mcp_tool_usage"
    expect(response).to have_http_status(:forbidden)
  end

  it "returns top tools, unused advertised tools, error rates, and surface breakdown" do
    repository = Factories.repository(user: admin)
    job = Factories.job(user: admin, repository: repository)
    run = job.initial_run
    chat = ChatSession.create!(user: admin, repository: repository)
    now = Time.zone.parse("2026-07-31 12:00:00")

    travel_to(now) do
      McpToolUsageRecorder.record_workflow_tool_call(
        run: run,
        tool_name: "syrus-mcp-sidecar.read_live_state",
        tool_use_id: "wf_1",
        tool_input: {}
      )
      McpToolUsageRecorder.record_workflow_tool_result(
        run: run,
        tool_name: "syrus-mcp-sidecar.read_live_state",
        tool_use_id: "wf_1",
        content: { "job" => job.id },
        error: false
      )
      McpToolUsageRecorder.record_chat_tool_call(
        chat_session: chat,
        tool_name: "mcp__syrus-chat-sidecar__repo_info",
        tool_use_id: "chat_1",
        tool_input: {},
        provider: "claude"
      )
      McpToolUsageRecorder.record_chat_tool_result(
        chat_session: chat,
        tool_name: "mcp__syrus-chat-sidecar__repo_info",
        tool_use_id: "chat_1",
        content: { "message" => "denied" },
        error: true,
        provider: "claude"
      )

      sign_in_as(admin)
      get "/api/v1/app/admin/mcp_tool_usage", params: {
        start: 1.hour.ago.iso8601,
        end: 1.hour.from_now.iso8601
      }
    end

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["totals"]).to eq("calls" => 2, "errors" => 1)
    expect(body["top_tools"].map { |row| row["tool_name"] }).to include("read_live_state", "repo_info")
    expect(body["error_rates"].find { |row| row["tool_name"] == "repo_info" }).to include(
      "calls" => 1,
      "errors" => 1,
      "error_rate" => 1.0
    )
    expect(body["surface_breakdown"]).to contain_exactly(
      include("surface" => "chat", "calls" => 1, "errors" => 1),
      include("surface" => "workflow", "calls" => 1, "errors" => 0)
    )
    expect(body["sidecar_mode_breakdown"]).to contain_exactly(
      include("sidecar_mode" => "stdio", "calls" => 2, "errors" => 1)
    )
    expect(body["unused_advertised_tools"]).to include("submit_summary")

    expect(body["provider_breakdown"]).to contain_exactly(
      include("provider" => "claude", "calls" => 2, "errors" => 1)
    )
    expect(body["server_breakdown"]).to contain_exactly(
      include("server_name" => "syrus-mcp-sidecar", "calls" => 1, "errors" => 0),
      include("server_name" => "syrus-chat-sidecar", "calls" => 1, "errors" => 1)
    )

    workflow = run.workflow
    recent_calls = body["recent_calls"]
    expect(recent_calls.size).to eq(2)

    workflow_call = recent_calls.find { |row| row["tool_name"] == "read_live_state" }
    expect(workflow_call).to include(
      "surface" => "workflow",
      "status" => "completed",
      "error" => false,
      "job_id" => job.id,
      "job_path" => "/jobs/#{job.id}",
      "workflow_id" => workflow.id,
      "workflow_path" => "/jobs/#{job.id}?tab=workflows#workflow-#{workflow.id}",
      "run_id" => run.id,
      "run_path" => "/admin/runs/#{run.id}/transcript",
      "chat_session_id" => nil,
      "chat_path" => nil
    )

    chat_call = recent_calls.find { |row| row["tool_name"] == "repo_info" }
    expect(chat_call).to include(
      "surface" => "chat",
      "status" => "failed",
      "error" => true,
      "job_id" => nil,
      "job_path" => nil,
      "chat_session_id" => chat.id,
      "chat_path" => "/chats/#{chat.id}"
    )
  end
end
