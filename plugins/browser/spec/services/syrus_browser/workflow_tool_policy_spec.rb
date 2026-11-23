require "rails_helper"

RSpec.describe "Browser workflow tool policy" do
  let(:run) { Factories.job.initial_run }

  def visual_context
    run.step.update_columns(kind: "visual_review")
    McpToolContext.from_run(run.reload)
  end

  def tool_names_for(context)
    McpToolRegistry.tools_for_context(context).map(&:tool_name)
  end

  it "maps the visual-review step kind to its reviewer role" do
    expect(AgentRole.for_step_kind("visual_review")).to eq(AgentRole::WORKFLOW_VISUAL_REVIEWER)
    expect(visual_context.role).to eq(AgentRole::WORKFLOW_VISUAL_REVIEWER)
  end

  it "exposes the visual-review submission tool instead of summary" do
    tools = McpToolPolicy.for(visual_context)

    expect(tools).to include(Mcp::Tools::SubmitVisualReviewTool)
    expect(tools).not_to include(Mcp::Tools::SubmitSummaryTool)
  end

  it "advertises generic runtime tools for a non-browser runtime session" do
    context = visual_context
    RuntimeSession.create!(
      repository: run.job.repository, job: run.job, workflow: run.workflow, run: run,
      workspace_ref: "/workspace", provider_key: "cli_tui", display_name: "Terminal", state: "running"
    )

    expect(McpToolPolicy.for(context)).to include(
      Mcp::Tools::RuntimeInspectTool,
      Mcp::Tools::RuntimeWaitTool,
      Mcp::Tools::RuntimeInputTool,
      Mcp::Tools::RuntimeCaptureArtifactTool
    )
  end

  it "exposes review tools but no session controls without a runtime target" do
    expect(tool_names_for(visual_context)).to contain_exactly(
      *%w[
        read_live_state
        get_coverage_report read_run_worker_health start_preview stop_preview
        read_preview_log search_jobs list_jobs list_open_prs read_pr list_ci_checks read_ci_log list_open_issues
        submit_visual_review submit_visual_artifact
        list_artifacts read_artifact
      ]
    )
  end
end
