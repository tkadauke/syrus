require "rails_helper"

# The MCP bridge is a transport for the chat MCP tool surface, not a second
# policy: an external client sees exactly what its bridge chat would offer,
# through the same permission gate, and its calls are recorded like any
# other chat call.
RSpec.describe "MCP bridge endpoint", type: :request do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:issued) { McpBridgeToken.issue!(user:, name: "laptop") }
  let(:token) { issued.first }
  let(:plaintext) { issued.last }

  def rpc(method, params = nil, bearer: plaintext)
    body = { jsonrpc: "2.0", id: 1, method: method }
    body[:params] = params if params
    headers = { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }
    headers["Authorization"] = "Bearer #{bearer}" if bearer
    post "/mcp/bridge", params: JSON.generate(body), headers: headers
    JSON.parse(response.body)
  end

  def call_tool(name, arguments = {}) = rpc("tools/call", { name:, arguments: })

  it "refuses a request without a token" do
    rpc("tools/list", bearer: nil)

    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to include("Bearer")
  end

  it "refuses the user's API token, an unknown token and a revoked one" do
    api_token = user.generate_api_token!
    token.revoke!

    [ api_token, "syrus_mcp_unknown", plaintext ].each do |bearer|
      rpc("tools/list", bearer:)
      expect(response).to have_http_status(:unauthorized), bearer
    end
  end

  it "rate-limits repeated bad tokens" do
    # The test env's cache is a null store; count in a real one.
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    McpBridge::Endpoint::BAD_TOKEN_LIMIT.times { rpc("tools/list", bearer: "syrus_mcp_guess") }

    rpc("tools/list", bearer: "syrus_mcp_guess")

    expect(response).to have_http_status(:too_many_requests)
  end

  it "lists exactly the tools the token's bridge chat offers, in a chat Syrus's agent never answers" do
    tools = rpc("tools/list").dig("result", "tools").map { |tool| tool["name"] }

    chat = token.reload.chat_session
    expect(chat).to be_mcp_bridge
    expect(chat.user).to eq(user)
    expect(tools).to match_array(Mcp::Sidecar.chat_tool_names(chat, tier: :all))
    expect(tools).to include("list_jobs", "explain_stuck_job")
    expect(token.last_used_at).to be_present
  end

  it "reuses the bridge chat across requests" do
    rpc("tools/list")
    first = token.reload.chat_session

    rpc("tools/list")

    expect(token.reload.chat_session).to eq(first)
  end

  it "runs an essential tool and records the call as a bridge call" do
    result = call_tool("list_jobs")

    expect(result.dig("result", "isError")).not_to be(true)
    usage = McpToolUsage.order(:id).last
    expect(usage).to have_attributes(sidecar_mode: "bridge", chat_session_id: token.reload.chat_session_id)
    expect(usage.tool_name).to eq("list_jobs")
  end

  it "routes a gated tool through the operator's decision in the bridge chat" do
    target = ChatSession.create!(user:)

    expect { call_tool("send_chat_message", { text: "hello", target_chat_session_id: target.id }) }
      .to change { ChatPendingAction.count }.by(1)

    action = ChatPendingAction.order(:id).last
    expect(action.chat_session).to eq(token.reload.chat_session)
    expect(target.messages.count).to eq(0)
  end
end
