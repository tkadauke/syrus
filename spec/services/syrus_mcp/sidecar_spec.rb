require "rails_helper"

# These specs build the same MCP::Server the sidecar does, but feed
# JSON-RPC frames directly through Server#handle_json instead of going
# through the StdioTransport. Avoids subprocess + Rails-boot overhead
# while still exercising the full handshake + tool registration that
# claude will see when it spawns the binary.
RSpec.describe Mcp::Sidecar do
  let(:run) { Factories.job.initial_run }

  def server_for(run)
    Mcp::Sidecar.workflow(run_id: run.id).build_server
  end

  def jsonrpc(server, method, id: 1, params: {})
    request = { jsonrpc: "2.0", id: id, method: method, params: params }.to_json
    raw = server.handle_json(request)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  describe "MCP handshake" do
    it "records the tool list when the workflow sidecar builds" do
      server_for(run)

      logs = run.job_logs.order(:sequence).map(&:chunk)
      expect(logs).to include(a_string_including(
        "[mcp_sidecar] build starting server=syrus-mcp-sidecar"
      ))
      expect(logs.last).to include(
        "[mcp_sidecar] build server=syrus-mcp-sidecar",
        "duration_ms=",
        "submit_summary"
      )
    end

    it "does not misclassify process termination during build as a build failure" do
      sidecar = described_class.new(
        server_name: described_class::WORKFLOW_SERVER,
        tools: -> { raise SystemExit.new(0) },
        server_context: -> { { run_id: run.id } }
      )

      expect { sidecar.build_server }.to raise_error(SystemExit)

      logs = run.job_logs.order(:sequence).map(&:chunk)
      expect(logs).to include(a_string_including("[mcp_sidecar] build starting server=syrus-mcp-sidecar"))
      expect(logs).not_to include(a_string_including("[mcp_sidecar] build failed"))
    end

    it "responds to `initialize` with serverInfo and a negotiated protocol version" do
      response = jsonrpc(server_for(run), "initialize", params: { protocolVersion: "2025-06-18", clientInfo: { name: "test", version: "1" }, capabilities: {} })
      expect(response[:result][:serverInfo]).to include(name: "syrus-mcp-sidecar")
      expect(response[:result][:protocolVersion]).to be_a(String)
    end

    it "advertises the run-scoped tools via `tools/list`" do
      _ = jsonrpc(server_for(run), "initialize", id: 0)
      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }
      expect(tool_names).to contain_exactly(
        *%w[read_live_state read_run_worker_health read_memory write_memory delete_memory search_memories list_memories get_coverage_report report_main_concern start_preview stop_preview read_preview_log submit_summary submit_test_plan submit_artifact submit_visual_artifact
            browser_navigate browser_click browser_fill browser_snapshot browser_screenshot browser_wait_for browser_close]
      )
      expect(tool_names).not_to include("submit_adversarial_review")
    end

    it "advertises workflow evidence tools for agent insight runs via `tools/list`" do
      Feature.find_or_create_by!(slug: "agent_insights") { |f| f.category = "Labs"; f.name = "Agent Insights" }
             .update!(enabled: true)
      Feature.clear_enabled_cache!("agent_insights")
      insight_job = Job.create!(user: run.job.user, repository: run.job.repository, kind: "agent_insight", priority: "low")
      insight_workflow = Workflows::AgentInsight.instantiate(job: insight_job)
      insight_step = insight_workflow.steps.find_by!(kind: "agent_insight_run")
      insight_run = insight_step.runs.first || insight_step.runs.create!(job: insight_job, trigger_kind: insight_workflow.trigger_kind)

      _ = jsonrpc(server_for(insight_run), "initialize", id: 0)
      response = jsonrpc(server_for(insight_run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).to include(
        "list_recent_workflows",
        "read_run_transcript",
        "submit_insight",
        "list_insights",
        "read_insight"
      )
      expect(tool_names).not_to include("submit_summary", "submit_test_plan")
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

      # MCP 1.x returns a tool-level error for missing required arguments.
      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to match(/Missing required arguments/)
    end
  end

  describe "tools/call submit_job_metadata" do
    it "persists canonical metadata when the run belongs to refresh_job_metadata" do
      run.step.update_columns(kind: "refresh_job_metadata")
      response = jsonrpc(server_for(run.reload), "tools/call", params: {
        name: "submit_job_metadata",
        arguments: {
          changed: true,
          title: "Preserve provider switching",
          summary: "The Job now preserves provider switching.",
          pr_body: "Preserves provider switching.",
          test_plan: { steps: [ "Run bin/rspec spec/services/syrus_mcp/sidecar_spec.rb" ] },
          intent_revision_reason: "Feedback changed the effective intent."
        }
      })

      expect(response[:result][:isError]).to be_falsey
      expect(run.workflow.reload.artifact("job_metadata")).to include(
        "changed" => true,
        "title" => "Preserve provider switching"
      )
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

  describe ".workflow" do
    it "stores only a run id context for later tool calls" do
      sidecar = described_class.workflow(run_id: run.id)

      expect(sidecar.instance_variable_get(:@server_name)).to eq("syrus-mcp-sidecar")
      expect(sidecar.instance_variable_get(:@server_context).call).to eq(run_id: run.id)
    end

    it "does not query the database during sidecar initialization" do
      expect(Run).not_to receive(:includes)

      sidecar = described_class.workflow(run_id: 0)

      expect(sidecar.instance_variable_get(:@server_context).call).to eq(run_id: 0)
    end
  end

  describe "policy-based tool composition" do
    it "advertises tools derived from McpToolPolicy" do
      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).to include("submit_summary", "read_live_state", "start_preview")
    end

    it "advertises and dispatches external workflow plugin tools" do
      stub_tool_set = Class.new do
        include Syrus::Plugin::McpToolSet

        def self.available_for?(_repo) = true

        def self.tool_definitions
          [ { name: "stub_ping", description: "A stub ping tool.", input_schema: {} } ]
        end

        def handle(_tool_name, _params, _context)
          MCP::Tool::Response.new([ { type: "text", text: "pong" } ])
        end
      end
      Syrus::PluginRegistry.register(
        name: "stub_plugin",
        version: "0.1.0",
        provides: { mcp_tool_set: stub_tool_set }
      )

      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }
      expect(tool_names).to include("stub_ping")
      build_log = run.job_logs.where("chunk LIKE ?", "%[mcp_sidecar] build%").order(:sequence).last.chunk
      expect(build_log).to include("stub_ping")
      expect(build_log).not_to include("class")

      response = jsonrpc(server_for(run), "tools/call", params: {
        name: "stub_ping",
        arguments: {}
      })
      expect(response.dig(:result, :content, 0, :text)).to eq("pong")
    end

    it "role-gates tools via McpToolPolicy — adversarial reviewer cannot call submit_summary" do
      review_run = begin
        job = Factories.job
        workflow = job.latest_workflow
        step = Step.create!(workflow: workflow, kind: "adversarial_review", position: 99)
        step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
      end

      response = jsonrpc(server_for(review_run), "tools/call", params: {
        name: "submit_summary",
        arguments: { pr_title: "x", pr_body: "y", summary: "z" }
      })

      expect(response[:error]).to be_present
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
        name: "unavailable_plugin",
        version: "0.1.0",
        provides: { mcp_tool_set: unavailable_tool_set }
      )

      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).not_to include("secret_tool")
      expect(tool_names).to include("submit_summary")
    end

    it "does not advertise Syrus Dev diagnostics while the plugin is disabled" do
      PluginRecord.find_by!(name: "syrus_dev").update!(enabled: false)

      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).not_to include("read_performance_diagnostics", "read_syrus_logs")
    end

    it "advertises Syrus Dev diagnostics for Syrus implementation runs when enabled" do
      syrus_repository = Factories.repository(user: run.job.user, owner: "tkadauke", name: "syrus")
      syrus_run = Factories.job(repository: syrus_repository, user: run.job.user).initial_run

      PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)

      response = jsonrpc(server_for(syrus_run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).to include("read_performance_diagnostics", "read_syrus_logs")
    end

    it "advertises only Syrus log search for Syrus insight runs when enabled" do
      Feature.find_or_create_by!(slug: "agent_insights") { |f| f.category = "Labs"; f.name = "Agent Insights" }
             .update!(enabled: true)
      Feature.clear_enabled_cache!("agent_insights")
      syrus_repository = Factories.repository(user: run.job.user, owner: "tkadauke", name: "syrus")
      insight_job = Job.create!(user: run.job.user, repository: syrus_repository, kind: "agent_insight", priority: "low")
      insight_workflow = Workflows::AgentInsight.instantiate(job: insight_job)
      insight_step = insight_workflow.steps.find_by!(kind: "agent_insight_run")
      insight_run = insight_step.runs.first || insight_step.runs.create!(job: insight_job, trigger_kind: insight_workflow.trigger_kind)

      PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)

      response = jsonrpc(server_for(insight_run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).to include("read_syrus_logs")
      expect(tool_names).not_to include("read_performance_diagnostics")
    end

    it "does not advertise Syrus Dev diagnostics for non-implementation workflow roles" do
      syrus_repository = Factories.repository(user: run.job.user, owner: "tkadauke", name: "syrus")
      job = Factories.job(repository: syrus_repository, user: run.job.user)
      workflow = job.workflows.first
      review_step = Step.create!(workflow: workflow, kind: "adversarial_review", position: 99)
      review_run = review_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)

      PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)

      response = jsonrpc(server_for(review_run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).not_to include("read_performance_diagnostics", "read_syrus_logs")
    end

    it "does not advertise Syrus Dev diagnostics for non-Syrus repositories" do
      PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)

      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).not_to include("read_performance_diagnostics", "read_syrus_logs")
    end

    it "still advertises core tools when the plugin registry is empty" do
      response = jsonrpc(server_for(run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).to include("read_live_state", "submit_summary")
      expect(tool_names).not_to include("read_performance_diagnostics", "read_syrus_logs")
    end
  end
end
