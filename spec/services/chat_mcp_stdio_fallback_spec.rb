require "rails_helper"
require "rack/mock"

RSpec.describe ChatMcpStdioFallback, :ci_only do
  let(:user) { Factories.user(claude_oauth_token: "oat-test", github_token: "ghp-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(user: user, repository: repository) }

  after do
    described_class.reset_for_test!
  end

  def enable_plugin!(name)
    PluginRecord.find_or_create_by!(name: name).update!(enabled: true, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  def list_tools(tier:)
    fallback = described_class.server
    response = post_jsonrpc(fallback, {
      jsonrpc: "2.0",
      id: "tools-#{tier}",
      method: "tools/list"
    }, token: fallback_token(fallback, tier: tier))

    expect(response[0]).to eq(200)
    JSON.parse(response[2].first).fetch("result").fetch("tools").map { |tool| tool.fetch("name") }
  end

  def call_tool(tier:, name:, arguments: {})
    fallback = described_class.server
    response = post_jsonrpc(fallback, {
      jsonrpc: "2.0",
      id: "call-#{name}",
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }, token: fallback_token(fallback, tier: tier))

    expect(response[0]).to eq(200)
    JSON.parse(response[2].first).fetch("result")
  end

  def fallback_token(fallback, tier:)
    McpInvocationContext.issue_for_chat(
      chat,
      worker_id: fallback.identity.fetch(:worker_id),
      tier: tier
    )
  end

  def post_jsonrpc(fallback, body, token:)
    env = Rack::MockRequest.env_for(
      PersistentMcpDaemon::MCP_PATH,
      method: "POST",
      input: body.to_json,
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream",
      "HTTP_X_SYRUS_INVOCATION_CONTEXT" => token
    )
    fallback.daemon.call(env)
  end

  it "exposes the planning chat surface, plugin tools, and no workflow-only tools" do
    enable_plugin!("mockups")
    enable_plugin!("whiteboard")
    enable_plugin!("mysql_db_browser")
    Factories.mysql_connection(agentic_access_enabled: true)

    essential = list_tools(tier: "essential")
    deferred = list_tools(tier: "deferred")
    names = essential + deferred

    expect(essential).to include("repo_info", "propose_job", "show_preview", "write_preview_file")
    expect(deferred).to include("draw_shape", "read_scene", "show_preview", "mysql_db_browser_list_connections")
    expect(names).to include("mysql_db_browser_execute_query")
    expect(names).not_to include("submit_summary", "run_target_prepare", "submit_adversarial_review")

    scene_result = call_tool(tier: "deferred", name: "read_scene")
    expect(scene_result["isError"]).to be_falsey
    expect(JSON.parse(scene_result.dig("content", 0, "text"))).to include("elements" => [])

    mysql_result = call_tool(tier: "deferred", name: "mysql_db_browser_list_connections")
    expect(mysql_result["isError"]).to be_falsey
    expect(JSON.parse(mysql_result.dig("content", 0, "text")).fetch("mysql_connections")).not_to be_empty
  end
end
