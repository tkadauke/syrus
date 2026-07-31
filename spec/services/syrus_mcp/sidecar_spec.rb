require "rails_helper"

# These specs build the MCP::Server via Sidecar#build_server, which reads
# the plugin registry. The `around` block registers CoreToolSet so the
# sidecar has its full default tool list, matching what production boots with.
#
# For composition tests (multi-tool-set, available_for? gating, collision),
# the inner examples manage the registry state themselves.
RSpec.describe SyrusMcp::Sidecar do
  let(:run) { Factories.job.initial_run }

  around do |ex|
    Syrus::PluginRegistry.reset!
    Syrus::PluginRegistry.register(
      name: "syrus_core_tools",
      version: "0.1.0",
      provides: { mcp_tool_set: SyrusMcp::CoreToolSet }
    )
    ex.run
    Syrus::PluginRegistry.reset!
  end

  def server_for(run)
    SyrusMcp::Sidecar.new(run_id: run.id).build_server
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

    it "advertises the run-scoped tools via `tools/list`" do
      _ = jsonrpc(server_for(run), "initialize", id: 0)
      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }
      expect(tool_names).to contain_exactly(
        *%w[read_live_state read_memory write_memory delete_memory search_memories list_memories get_coverage_report report_main_concern submit_summary submit_test_plan]
      )
      expect(tool_names).not_to include("submit_adversarial_review")
    end

    it "exposes read_live_state as a read-only tool without arbitrary job lookup arguments" do
      _ = jsonrpc(server_for(run), "initialize", id: 0)
      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool = response[:result][:tools].find { |candidate| candidate[:name] == "read_live_state" }

      expect(tool[:description]).to include("read-only")
      expect(tool[:inputSchema][:properties].keys).to eq([ :detail ])
    end
  end

  describe "tools/call read_live_state" do
    it "returns compact state for the current Run via the JSON-RPC path" do
      response = jsonrpc(server_for(run), "tools/call", params: {
        name: "read_live_state",
        arguments: {}
      })

      expect(response[:result][:isError]).to be_falsey
      payload = JSON.parse(response[:result][:content].first[:text])
      expect(payload.dig("job", "id")).to eq(run.job_id)
      expect(payload.dig("run", "id")).to eq(run.id)
      expect(payload).to include("workflow", "queue", "chat")
      expect(payload.dig("links", "api_job")).to eq("/api/v1/admin/jobs/#{run.job_id}")
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

  describe "tools/call submit_test_plan" do
    it "persists the test plan on the Workflow via the JSON-RPC path" do
      response = jsonrpc(server_for(run), "tools/call", params: {
        name: "submit_test_plan",
        arguments: {
          steps: [ "Run bin/rspec spec/services/steps/test_plan_spec.rb" ],
          notes: "Manual check for PR copy."
        }
      })

      expect(response[:result][:isError]).to be_falsey
      expect(run.workflow.reload.artifact("test_plan")).to eq(
        "steps" => [ "Run bin/rspec spec/services/steps/test_plan_spec.rb" ],
        "notes" => "Manual check for PR copy."
      )
    end
  end

  describe "tools/call submit_adversarial_review" do
    # Adversarial review is role-gated: only runs whose step.kind == "grader"
    # (WORKFLOW_ADVERSARIAL_REVIEWER) have this tool in their sidecar tool list.
    let(:grader_run) do
      job = Factories.job
      workflow = job.latest_workflow
      step = Step.create!(workflow: workflow, kind: "grader", position: 99)
      step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
    end

    it "persists the review findings on the Workflow via the JSON-RPC path" do
      response = jsonrpc(server_for(grader_run), "tools/call", params: {
        name: "submit_adversarial_review",
        arguments: {
          critique: "No blocking issues found.",
          verdict: "approved"
        }
      })

      expect(response[:result][:isError]).to be_falsey
      expect(grader_run.workflow.reload.artifact("adversarial_review_iterations")).to eq([
        {
          "iteration" => grader_run.step.iteration,
          "critique" => "No blocking issues found.",
          "verdict" => "approved"
        }
      ])
    end

    it "returns not_authorized when called from a non-grader step (implement role)" do
      response = jsonrpc(server_for(run), "tools/call", params: {
        name: "submit_adversarial_review",
        arguments: { critique: "x", verdict: "approved" }
      })

      # The tool is not registered in the implement-role sidecar, so the
      # MCP server returns a JSON-RPC error (method not found).
      expect(response[:error]).to be_present
    end
  end

  describe ".new(run_id:)" do
    it "stores only the id for later tool calls" do
      sidecar = described_class.new(run_id: run.id)
      expect(sidecar.instance_variable_get(:@run_id)).to eq(run.id)
      expect(sidecar.instance_variable_get(:@run)).to be_nil
    end

    it "does not query the database during sidecar initialization" do
      expect(SyrusMcp).not_to receive(:run_from_context)

      sidecar = described_class.new(run_id: 0)

      expect(sidecar.instance_variable_get(:@run_id)).to eq(0)
    end
  end

  describe "registry-based tool composition", :reset_plugin_registry do
    around do |ex|
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(
        name: "syrus-claude-agent",
        version: SyrusClaudeAgent::VERSION,
        provides: { agent_provider: AgentProviders::Claude }
      )
      Syrus::PluginRegistry.register(
        name: "syrus-codex-agent",
        version: SyrusCodexAgent::VERSION,
        provides: { agent_provider: AgentProviders::Codex }
      )
      ex.run
      Syrus::PluginRegistry.reset!
    end

    it "advertises tools from all registered tool sets" do
      stub_tool_set = Class.new do
        include Syrus::Plugin::McpToolSet
        def self.available_for?(_repo) = true
        def self.tool_definitions
          [ { name: "stub_ping", description: "A stub ping tool.", input_schema: {} } ]
        end
        def handle(tool_name, params, context)
          MCP::Tool::Response.new([ { type: "text", text: "pong" } ])
        end
      end

      Syrus::PluginRegistry.register(
        name: "syrus_core_tools",
        version: "0.1.0",
        provides: { mcp_tool_set: SyrusMcp::CoreToolSet }
      )
      Syrus::PluginRegistry.register(
        name: "stub_plugin",
        version: "0.1.0",
        provides: { mcp_tool_set: stub_tool_set }
      )

      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).to include("submit_summary", "read_live_state", "stub_ping")
    end

    it "dispatches tools/call to the correct tool set" do
      handled_by = nil
      stub_tool_set = Class.new do
        include Syrus::Plugin::McpToolSet
        def self.available_for?(_repo) = true
        def self.tool_definitions
          [ { name: "stub_ping", description: "A stub tool.", input_schema: {} } ]
        end
        define_method(:handle) do |tool_name, params, context|
          handled_by = :stub
          MCP::Tool::Response.new([ { type: "text", text: "pong" } ])
        end
      end

      Syrus::PluginRegistry.register(
        name: "syrus_core_tools",
        version: "0.1.0",
        provides: { mcp_tool_set: SyrusMcp::CoreToolSet }
      )
      Syrus::PluginRegistry.register(
        name: "stub_plugin",
        version: "0.1.0",
        provides: { mcp_tool_set: stub_tool_set }
      )

      response = jsonrpc(server_for(run), "tools/call", params: {
        name: "stub_ping",
        arguments: {}
      })

      expect(response[:result][:isError]).to be_falsey
      expect(handled_by).to eq(:stub)
    end

    it "excludes tools from a tool set whose available_for? returns false" do
      unavailable_tool_set = Class.new do
        include Syrus::Plugin::McpToolSet
        def self.available_for?(_repo) = false
        def self.tool_definitions
          [ { name: "secret_tool", description: "Hidden.", input_schema: {} } ]
        end
        def handle(tool_name, params, context) = nil
      end

      Syrus::PluginRegistry.register(
        name: "syrus_core_tools",
        version: "0.1.0",
        provides: { mcp_tool_set: SyrusMcp::CoreToolSet }
      )
      Syrus::PluginRegistry.register(
        name: "unavailable_plugin",
        version: "0.1.0",
        provides: { mcp_tool_set: unavailable_tool_set }
      )

      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).not_to include("secret_tool")
      expect(tool_names).to include("submit_summary")
    end

    it "advertises no tools when the registry is empty" do
      response = jsonrpc(server_for(run), "tools/list", id: 1)
      expect(response[:result][:tools]).to be_empty
    end
  end
end
