require "rails_helper"

# These specs build the same MCP::Server the sidecar does, but feed
# JSON-RPC frames directly through Server#handle_json instead of going
# through the StdioTransport. Avoids subprocess + Rails-boot overhead
# while still exercising the full handshake + tool registration that
# claude will see when it spawns the binary.
RSpec.describe SyrusMcp::Sidecar do
  let(:run) { Factories.job.initial_run }

  def server_for(run)
    MCP::Server.new(
      name: "syrus-mcp-sidecar",
      tools: [ SyrusMcp::SubmitSummaryTool ],
      server_context: { run_id: run.id }
    )
  end

  def jsonrpc(server, method, id: 1, params: {})
    request = { jsonrpc: "2.0", id: id, method: method, params: params }.to_json
    raw = server.handle_json(request)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  describe "MCP handshake" do
    it "responds to `initialize` with serverInfo and a negotiated protocol version" do
      response = jsonrpc(server_for(run), "initialize", params: { protocolVersion: "2025-06-18", clientInfo: { name: "test", version: "1" } })
      expect(response[:result][:serverInfo]).to include(name: "syrus-mcp-sidecar")
      expect(response[:result][:protocolVersion]).to be_a(String)
    end

    it "advertises the submit_summary tool via `tools/list`" do
      _ = jsonrpc(server_for(run), "initialize", id: 0)
      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }
      expect(tool_names).to eq(%w[submit_summary])
    end
  end

  describe "tools/call submit_summary" do
    it "persists the agent submission on the Run via the JSON-RPC path" do
      response = jsonrpc(server_for(run), "tools/call", params: {
        name: "submit_summary",
        arguments: {
          pr_title: "Add greet helper",
          pr_body:  "Adds a tiny greet helper used by the welcome page.",
          summary:  "Wrote the greet helper. Tests pass."
        }
      })

      expect(response[:result][:isError]).to be_falsey
      expect(run.reload).to have_attributes(
        agent_pr_title: "Add greet helper",
        agent_pr_body:  "Adds a tiny greet helper used by the welcome page.",
        agent_summary:  "Wrote the greet helper. Tests pass."
      )
    end

    it "returns an MCP error response (not an exception) when arguments fail validation" do
      response = jsonrpc(server_for(run), "tools/call", params: {
        name: "submit_summary",
        arguments: { pr_title: "", pr_body: "x", summary: "y" }
      })

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to match(/pr_title is required/)
    end

    it "rejects calls missing required arguments at the schema layer" do
      response = jsonrpc(server_for(run), "tools/call", params: {
        name: "submit_summary",
        arguments: { pr_title: "x" }   # pr_body + summary missing
      })

      # Server returns a JSON-RPC error here, not a tool error.
      expect(response[:error]).to be_present
      expect(response[:error][:code]).to eq(-32602)  # JSON-RPC "invalid params"
      expect(response[:error][:data]).to match(/Missing required arguments/)
    end
  end

  describe ".new(run_id:)" do
    it "validates the Run id and stores only the id for later tool calls" do
      sidecar = described_class.new(run_id: run.id)
      expect(sidecar.instance_variable_get(:@run_id)).to eq(run.id)
      expect(sidecar.instance_variable_get(:@run)).to be_nil
    end

    it "raises ActiveRecord::RecordNotFound for an unknown run_id" do
      expect { described_class.new(run_id: 0) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
