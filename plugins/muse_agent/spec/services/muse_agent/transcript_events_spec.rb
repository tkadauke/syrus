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

  it "normalizes Muse envelope events without surfacing raw envelope noise" do
    jsonl = [
      {
        record_type: "event",
        payload_type: "run.started",
        timestamp: "2026-09-15T10:00:00Z",
        payload: {
          session_id: "muse-session",
          model: "muse-spark-test",
          cwd: "/repo"
        }
      },
      {
        record_type: "event",
        payload_type: "turn.input.user",
        timestamp: "2026-09-15T10:00:01Z",
        payload: { content: [ { type: "text", text: "Summarize the run." } ] }
      },
      {
        record_type: "event",
        payload_type: "run.output.delta",
        timestamp: "2026-09-15T10:00:02Z",
        payload: { delta: "Working on it." }
      },
      {
        record_type: "event",
        payload_type: "mcp.tool.call",
        timestamp: "2026-09-15T10:00:03Z",
        payload: {
          server: "syrus-mcp-sidecar",
          name: "submit_summary",
          arguments: { title: "Render Muse transcripts" }.to_json,
          invocation_id: "call-1"
        }
      },
      {
        record_type: "event",
        payload_type: "mcp.tool.result",
        timestamp: "2026-09-15T10:00:04Z",
        payload: {
          server_name: "syrus-mcp-sidecar",
          tool_name: "submit_summary",
          output: { ok: true },
          invocation_id: "call-1"
        }
      },
      {
        record_type: "event",
        payload_type: "task.lifecycle.failed",
        timestamp: "2026-09-15T10:00:05Z",
        payload: { task_id: "task-1", message: "optional background task failed" }
      },
      {
        record_type: "event",
        payload_type: "run.terminal.completed",
        timestamp: "2026-09-15T10:00:06Z",
        payload: { status: "completed", turns: 2, session_id: "muse-session", final_text: "Done." }
      }
    ].map(&:to_json).join("\n")

    events = ClaudeTranscript.new(jsonl).events.to_a
    summary = ClaudeTranscript.new(jsonl).summary

    expect(events.map(&:kind)).to eq([ :system_init, :user_prompt, :assistant_text, :tool_use, :tool_result, :other, :result ])
    expect(events.second.data).to eq(text: "Summarize the run.")
    expect(events.third.data).to eq(text: "Working on it.")
    expect(events.fourth.data).to include(
      name: "syrus-mcp-sidecar.submit_summary",
      input: { "title" => "Render Muse transcripts" },
      id: "call-1"
    )
    expect(events.fifth.data).to include(
      name: "syrus-mcp-sidecar.submit_summary",
      tool_use_id: "call-1",
      content: { "ok" => true },
      error: false
    )
    expect(events[5].data).to eq(
      type: "task.lifecycle.failed",
      message: "optional background task failed",
      task_id: "task-1"
    )
    expect(summary).to have_attributes(
      session_id: "muse-session",
      model: "muse-spark-test",
      cwd: "/repo",
      total_turns: 2,
      exit_reason: "completed"
    )
    expect(summary.tool_call_counts).to include("syrus-mcp-sidecar.submit_summary" => 1)
  end

  it "uses terminal Muse metadata when the transcript has no separate init event" do
    jsonl = [
      {
        record_type: "event",
        payload_type: "run.terminal.failed",
        payload: {
          session_id: "terminal-session",
          model: "muse-spark-test",
          workspace: "/repo",
          outcome: "auth_error",
          message: "HTTP 401 Unauthorized"
        }
      }
    ].map(&:to_json).join("\n")

    summary = ClaudeTranscript.new(jsonl).summary

    expect(summary.session_id).to eq("terminal-session")
    expect(summary.model).to eq("muse-spark-test")
    expect(summary.cwd).to eq("/repo")
    expect(summary.exit_reason).to eq("auth_error")
  end
end
