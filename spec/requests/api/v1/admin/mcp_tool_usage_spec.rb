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
  end
end
