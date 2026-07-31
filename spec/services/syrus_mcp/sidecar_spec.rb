require "rails_helper"

# These specs build the same MCP::Server the sidecar does, but feed
# JSON-RPC frames directly through Server#handle_json instead of going
# through the StdioTransport. Avoids subprocess + Rails-boot overhead
# while still exercising the full handshake + tool registration that
# claude will see when it spawns the binary.
RSpec.describe SyrusMcp::Sidecar do
  let(:run) { Factories.job.initial_run }

  def server_for(run)
    context = McpToolContext.from_run(Run.includes(:step, job: :repository).find(run.id))
    MCP::Server.new(
      name: "syrus-mcp-sidecar",
      tools: McpToolPolicy.for(context),
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

    it "advertises the run-scoped tools via `tools/list`" do
      _ = jsonrpc(server_for(run), "initialize", id: 0)
      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }
      expect(tool_names).to contain_exactly(
        *%w[read_live_state read_run_worker_health read_memory write_memory delete_memory search_memories list_memories get_coverage_report report_main_concern submit_summary submit_test_plan]
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
    # Adversarial review is role-gated: only runs whose step.kind ==
    # "adversarial_review" have this tool in their sidecar tool list.
    let(:review_run) do
      job = Factories.job
      workflow = job.latest_workflow
      step = Step.create!(workflow: workflow, kind: "adversarial_review", position: 99)
      step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
    end

    it "persists the review findings on the Workflow via the JSON-RPC path" do
      response = jsonrpc(server_for(review_run), "tools/call", params: {
        name: "submit_adversarial_review",
        arguments: {
          critique: "No blocking issues found.",
          verdict: "approved"
        }
      })

      expect(response[:result][:isError]).to be_falsey
      expect(review_run.workflow.reload.artifact("adversarial_review_iterations")).to eq([
        {
          "iteration" => review_run.step.iteration,
          "critique" => "No blocking issues found.",
          "verdict" => "approved"
        }
      ])
    end

    it "returns not_authorized when called from a non-review step (implement role)" do
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
end
