require "rails_helper"

# The daemon prepends ChatToolDispatch and WorkflowToolDispatch onto the same
# tool class when a tool is served on both routes (the coworkers' list_chats
# and search_chats), each once, on first use. With the chat wrapper outermost,
# a workflow-route call carrying a run token reached chat resolution and was
# refused ("invocation token surface :run is not chat"), so whether coworker
# workflow calls worked depended on which route wrapped the tool first
# (formal/SyrusModel/DispatchOrder.lean).
RSpec.describe "persistent daemon dispatch wrapper order" do
  let(:tool) do
    Class.new(MCP::Tool) do
      tool_name "dispatch_order_probe"
      description "probe"
      input_schema(properties: {})

      def self.call(server_context: nil, **)
        MCP::Tool::Response.new([ { type: "text", text: "served" } ])
      end
    end
  end

  it "lets a workflow-route call through the chat wrapper when the chat wrapper is outermost" do
    # Only the two route wrappers are under test; the capability authorization
    # layer ChatToolDispatch.wrap also installs needs a real Run context.
    allow(Mcp::Sidecar).to receive(:authorize_tool) { |wrapped| wrapped }
    PersistentMcpDaemon::WorkflowToolDispatch.wrap(tool)
    PersistentMcpDaemon::ChatToolDispatch.wrap(tool)
    allow(PersistentMcpDaemon::WorkflowContextResolver).to receive(:resolve).and_return(
      double(tool_context: double(run: nil), provider: "codex", allowed_tool_names: [ "dispatch_order_probe" ], server_context: {})
    )
    allow(McpToolRegistry).to receive(:tool_name_for).and_call_original
    allow(McpToolRegistry).to receive(:tool_name_for).with(tool).and_return("dispatch_order_probe")

    response = tool.call(server_context: { identity: { worker_id: "w1" }, workflow_role: AgentRole::COWORKER })

    expect(response.content.first[:text]).to eq("served")
  end
end
