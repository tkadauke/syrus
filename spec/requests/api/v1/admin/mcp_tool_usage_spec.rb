require "rails_helper"

RSpec.describe "API: /api/v1/admin/mcp_tool_usage", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let!(:admin_token) { admin.generate_api_token! }

  def auth
    { "Authorization" => "Bearer #{admin_token}" }
  end

  def parse_body
    JSON.parse(response.body)
  end

  it "requires an admin API token" do
    get "/api/v1/admin/mcp_tool_usage"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns usage summary for API clients" do
    repository = Factories.repository(user: admin)
    run = Factories.job(user: admin, repository: repository).initial_run
    McpToolUsageRecorder.record_workflow_tool_call(
      run: run,
      tool_name: "syrus-mcp-sidecar.read_live_state",
      tool_use_id: "wf_1",
      tool_input: {}
    )

    get "/api/v1/admin/mcp_tool_usage", headers: auth, params: { surface: "workflow" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["surface"]).to eq("workflow")
    expect(body["totals"]).to include("calls" => 1)
    expect(body["top_tools"].first).to include(
      "tool_name" => "read_live_state",
      "server_name" => "syrus-mcp-sidecar",
      "calls" => 1
    )
    expect(body["provider_breakdown"]).to be_an(Array)
    expect(body["server_breakdown"]).to contain_exactly(
      include("server_name" => "syrus-mcp-sidecar", "calls" => 1)
    )
    expect(body["recent_calls"].first).to include(
      "tool_name" => "read_live_state",
      "surface" => "workflow",
      "job_path" => "/jobs/#{run.job.id}",
      "run_path" => "/admin/runs/#{run.id}/transcript"
    )
  end

  it "accepts relative since windows for API clients" do
    repository = Factories.repository(user: admin)
    run = Factories.job(user: admin, repository: repository).initial_run
    now = Time.zone.parse("2026-08-24 12:00:00")

    travel_to(now - 23.hours) do
      McpToolUsageRecorder.record_workflow_tool_call(
        run: run,
        tool_name: "syrus-mcp-sidecar.submit_summary",
        tool_use_id: "recent",
        tool_input: {}
      )
    end

    travel_to(now - 25.hours) do
      McpToolUsageRecorder.record_workflow_tool_call(
        run: run,
        tool_name: "syrus-mcp-sidecar.submit_test_plan",
        tool_use_id: "old",
        tool_input: {}
      )
    end

    travel_to(now) do
      get "/api/v1/admin/mcp_tool_usage", headers: auth, params: { since: "24h" }
    end

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(Time.zone.parse(body.dig("window", "start"))).to eq(now - 24.hours)
    expect(body["totals"]).to include("calls" => 1)
    expect(body["recent_calls"].map { |call| call["tool_name"] }).to eq([ "submit_summary" ])
  end

  it "accepts relative window presets without a since timestamp" do
    repository = Factories.repository(user: admin)
    run = Factories.job(user: admin, repository: repository).initial_run
    now = Time.zone.parse("2026-08-24 12:00:00")

    travel_to(now - 2.days) do
      McpToolUsageRecorder.record_workflow_tool_call(
        run: run,
        tool_name: "syrus-mcp-sidecar.read_live_state",
        tool_use_id: "two_days",
        tool_input: {}
      )
    end

    travel_to(now - 8.days) do
      McpToolUsageRecorder.record_workflow_tool_call(
        run: run,
        tool_name: "syrus-mcp-sidecar.submit_summary",
        tool_use_id: "eight_days",
        tool_input: {}
      )
    end

    travel_to(now) do
      get "/api/v1/admin/mcp_tool_usage", headers: auth, params: { window: "7d" }
    end

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["totals"]).to include("calls" => 1)
    expect(body["recent_calls"].map { |call| call["tool_name"] }).to eq([ "read_live_state" ])
  end

  it "filters recent calls and aggregates by tool and server" do
    repository = Factories.repository(user: admin)
    run = Factories.job(user: admin, repository: repository).initial_run

    McpToolUsageRecorder.record_workflow_tool_call(
      run: run,
      tool_name: "syrus-mcp-sidecar.submit_test_plan",
      tool_use_id: "wanted",
      tool_input: {}
    )
    McpToolUsageRecorder.record_workflow_tool_call(
      run: run,
      tool_name: "syrus-mcp-sidecar.submit_summary",
      tool_use_id: "other_tool",
      tool_input: {}
    )
    McpToolUsageRecorder.record_workflow_tool_call(
      run: run,
      tool_name: "syrus-chat-sidecar.submit_test_plan",
      tool_use_id: "other_server",
      tool_input: {}
    )

    get "/api/v1/admin/mcp_tool_usage", headers: auth, params: {
      tool_name: "submit_test_plan",
      server_name: "syrus-mcp-sidecar"
    }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["filters"]).to eq(
      "tool_name" => "submit_test_plan",
      "server_name" => "syrus-mcp-sidecar"
    )
    expect(body["totals"]).to include("calls" => 1)
    expect(body["top_tools"]).to contain_exactly(
      include("tool_name" => "submit_test_plan", "server_name" => "syrus-mcp-sidecar", "calls" => 1)
    )
    expect(body["recent_calls"].map { |call| [ call["tool_name"], call["server_name"] ] }).to eq(
      [ [ "submit_test_plan", "syrus-mcp-sidecar" ] ]
    )
  end
end
