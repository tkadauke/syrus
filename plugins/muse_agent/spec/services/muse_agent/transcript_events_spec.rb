require "rails_helper"

RSpec.describe MuseAgent::TranscriptEvents do
  it "normalizes Muse JSONL into transcript summary tool health" do
    jsonl = [
      {
        record_type: "event",
        payload_type: "mcp.tools",
        payload: {
          session_id: "muse-session",
          model: "muse-spark-test",
          workspace: "/tmp/worktree",
          tools: [ "syrus-mcp-sidecar.submit_summary" ]
        }
      },
      {
        record_type: "event",
        payload_type: "tool.call",
        payload: {
          server: "syrus-mcp-sidecar",
          tool: "submit_summary",
          input: { title: "Done" },
          id: "tool-1"
        }
      },
      {
        record_type: "event",
        payload_type: "run.terminal.completed",
        payload: { outcome: "success", turns: 1, final_text: "ok" }
      }
    ].map(&:to_json).join("\n")

    summary = ClaudeTranscript.new(jsonl).summary

    expect(summary.session_id).to eq("muse-session")
    expect(summary.model).to eq("muse-spark-test")
    expect(summary.cwd).to eq("/tmp/worktree")
    expect(summary.available_tools_at_init).to eq([ "syrus-mcp-sidecar.submit_summary" ])
    expect(summary.tool_call_counts).to include("syrus-mcp-sidecar.submit_summary" => 1)
    expect(summary).to be_mcp_tool_called
    expect(summary.exit_reason).to eq("success")
  end
end
