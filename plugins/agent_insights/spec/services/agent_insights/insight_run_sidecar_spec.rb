require "rails_helper"

# The insight run's own MCP surface, built through the real workflow sidecar
# the way the agent CLI sees it: the plugin's tools plus whatever core and
# other plugins grant the AgentRole::AGENT_INSIGHT role.
RSpec.describe Mcp::Sidecar, "agent insight runs" do
  let(:run) { Factories.job.initial_run }

  before { PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: true, disableable: true) }

  def server_for(run)
    Mcp::Sidecar.workflow(run_id: run.id).build_server
  end

  def jsonrpc(server, method, id: 1, params: {})
    request = { jsonrpc: "2.0", id: id, method: method, params: params }.to_json
    raw = server.handle_json(request)
    raw && JSON.parse(raw, symbolize_names: true)
  end

    it "advertises workflow evidence tools for agent insight runs via `tools/list`" do
      insight_job = Job.create!(user: run.job.user, repository: run.job.repository, kind: "agent_insight", priority: "low")
      insight_workflow = AgentInsights::Workflow.instantiate(job: insight_job)
      insight_step = insight_workflow.steps.find_by!(kind: "agent_insight_run")
      insight_run = insight_step.runs.first || insight_step.runs.create!(job: insight_job, trigger_kind: insight_workflow.trigger_kind)

      _ = jsonrpc(server_for(insight_run), "initialize", id: 0)
      response = jsonrpc(server_for(insight_run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).to include(
        "list_recent_workflows",
        "read_run_transcript",
        "list_repository_test_insights",
        "read_test_insight",
        "read_job_test_results",
        "read_run_test_results",
        "compare_test_runtime",
        "submit_insight",
        "list_insights",
        "read_insight"
      )
      expect(tool_names).not_to include("submit_summary", "submit_test_plan")
    end

    it "advertises only Syrus log search for Syrus insight runs when enabled" do
      syrus_repository = Factories.repository(user: run.job.user, owner: "tkadauke", name: "syrus")
      insight_job = Job.create!(user: run.job.user, repository: syrus_repository, kind: "agent_insight", priority: "low")
      insight_workflow = AgentInsights::Workflow.instantiate(job: insight_job)
      insight_step = insight_workflow.steps.find_by!(kind: "agent_insight_run")
      insight_run = insight_step.runs.first || insight_step.runs.create!(job: insight_job, trigger_kind: insight_workflow.trigger_kind)

      PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)

      response = jsonrpc(server_for(insight_run), "tools/list", id: 1)
      tool_names = response[:result][:tools].map { |t| t[:name] }

      expect(tool_names).to include("read_syrus_logs")
      expect(tool_names).not_to include("read_performance_diagnostics")
    end
end
