require "rails_helper"

RSpec.describe CodexAgent::TranscriptEvents do
  def jsonl(*lines)
    lines.map(&:to_json).join("\n") + "\n"
  end

  describe "Codex rollout JSONL compatibility" do
    let(:input) do
      jsonl(
        {
          "timestamp" => "2026-05-07T18:00:00Z",
          "type" => "session_meta",
          "payload" => { "id" => "019e-codex", "cwd" => "/work", "model" => "gpt-5.2-codex" }
        },
        {
          "timestamp" => "2026-05-07T18:00:01Z",
          "type" => "event_msg",
          "payload" => { "type" => "user_message", "message" => "Do the thing" }
        },
        {
          "timestamp" => "2026-05-07T18:00:02Z",
          "type" => "response_item",
          "payload" => {
            "type" => "function_call",
            "namespace" => "mcp__syrus__",
            "name" => "submit_summary",
            "arguments" => { pr_title: "Add thing" }.to_json,
            "call_id" => "call_1"
          }
        },
        {
          "timestamp" => "2026-05-07T18:00:03Z",
          "type" => "event_msg",
          "payload" => { "type" => "agent_message", "message" => "Done." }
        },
        {
          "timestamp" => "2026-05-07T18:00:04Z",
          "type" => "event_msg",
          "payload" => { "type" => "task_complete", "last_agent_message" => "Done.", "duration_ms" => 1234 }
        }
      )
    end

    it "extracts core events from Codex rollout files" do
      events = ClaudeTranscript.new(input).events.to_a
      expect(events.map(&:kind)).to include(:system_init, :user_prompt, :tool_use, :assistant_text, :result)
      expect(events.find { |e| e.kind == :tool_use }.data[:name]).to eq("mcp__syrus__submit_summary")
    end

    it "summarizes Codex sessions with MCP usage" do
      summary = ClaudeTranscript.new(input).summary
      expect(summary.session_id).to eq("019e-codex")
      expect(summary.cwd).to eq("/work")
      expect(summary.mcp_tool_called?).to be true
      expect(summary.tool_call_counts).to eq("mcp__syrus__submit_summary" => 1)
      expect(summary.exit_reason).to eq("success")
    end
  end

  describe "Codex exec JSONL compatibility" do
    let(:input) do
      jsonl(
        {
          "timestamp" => "2026-06-01T10:00:00Z",
          "type" => "thread.started",
          "thread_id" => "codex-thread-1",
          "cwd" => "/work",
          "model" => "gpt-5.5"
        },
        {
          "timestamp" => "2026-06-01T10:00:01Z",
          "type" => "item.completed",
          "item" => { "type" => "agent_message", "text" => "I will inspect the file." }
        },
        {
          "timestamp" => "2026-06-01T10:00:02Z",
          "type" => "item.started",
          "item" => {
            "type" => "mcp_tool_call",
            "server" => "syrus-mcp-sidecar",
            "tool" => "submit_summary",
            "arguments" => { "pr_title" => "Add thing" },
            "call_id" => "call_1"
          }
        },
        {
          "timestamp" => "2026-06-01T10:00:03Z",
          "type" => "item.completed",
          "item" => {
            "type" => "mcp_tool_call",
            "server" => "syrus-mcp-sidecar",
            "tool" => "submit_summary",
            "result" => { "ok" => true },
            "call_id" => "call_1"
          }
        },
        {
          "timestamp" => "2026-06-01T10:00:04Z",
          "type" => "item.started",
          "item" => { "type" => "command_execution", "command" => "bin/rspec", "id" => "cmd_1" }
        },
        {
          "timestamp" => "2026-06-01T10:00:05Z",
          "type" => "turn.completed",
          "usage" => { "input_tokens" => 10, "output_tokens" => 20 }
        }
      )
    end

    it "normalizes current Codex exec events into transcript events" do
      events = ClaudeTranscript.new(input).events.to_a
      expect(events.map(&:kind)).to eq([ :system_init, :assistant_text, :tool_use, :tool_result, :tool_use, :result ])
      expect(events[2].data).to include(
        name: "mcp__syrus-mcp-sidecar__submit_summary",
        id: "call_1"
      )
      expect(events[4].data).to include(
        name: "command_execution",
        input: { command: "bin/rspec" },
        id: "cmd_1"
      )
      expect(events.last.data).to include(subtype: "success", usage: { "input_tokens" => 10, "output_tokens" => 20 })
    end

    it "summarizes current Codex exec sessions" do
      summary = ClaudeTranscript.new(input).summary
      expect(summary.session_id).to eq("codex-thread-1")
      expect(summary.model).to eq("gpt-5.5")
      expect(summary.cwd).to eq("/work")
      expect(summary.total_turns).to eq(1)
      expect(summary.exit_reason).to eq("success")
      expect(summary.mcp_tool_called?).to be true
      expect(summary.tool_call_counts).to include(
        "mcp__syrus-mcp-sidecar__submit_summary" => 1,
        "command_execution" => 1
      )
    end

    it "counts completed MCP tool calls when Codex transcript omits the matching started item" do
      input = jsonl(
        {
          "timestamp" => "2026-06-01T10:00:00Z",
          "type" => "thread.started",
          "thread_id" => "codex-thread-1"
        },
        {
          "timestamp" => "2026-06-01T10:00:03Z",
          "type" => "item.completed",
          "item" => {
            "type" => "mcp_tool_call",
            "server" => "syrus-mcp-sidecar",
            "tool" => "submit_visual_review",
            "result" => { "ok" => true },
            "call_id" => "call_visual_review"
          }
        },
        {
          "timestamp" => "2026-06-01T10:00:04Z",
          "type" => "item.completed",
          "item" => {
            "type" => "mcp_tool_call",
            "server" => "syrus-mcp-sidecar",
            "tool" => "submit_adversarial_review",
            "result" => { "ok" => true },
            "call_id" => "call_adversarial_review"
          }
        },
        {
          "timestamp" => "2026-06-01T10:00:05Z",
          "type" => "item.completed",
          "item" => {
            "type" => "mcp_tool_call",
            "server" => "syrus-mcp-sidecar",
            "tool" => "submit_summary",
            "result" => { "ok" => true },
            "call_id" => "call_summary"
          }
        },
        {
          "timestamp" => "2026-06-01T10:00:06Z",
          "type" => "item.completed",
          "item" => {
            "type" => "mcp_tool_call",
            "server" => "syrus-mcp-sidecar",
            "tool" => "submit_test_plan",
            "result" => { "ok" => true },
            "call_id" => "call_test_plan"
          }
        }
      )

      summary = ClaudeTranscript.new(input).summary

      expect(summary.mcp_tool_called?).to be true
      expect(summary.tool_call_counts).to include(
        "mcp__syrus-mcp-sidecar__submit_visual_review" => 1,
        "mcp__syrus-mcp-sidecar__submit_adversarial_review" => 1,
        "mcp__syrus-mcp-sidecar__submit_summary" => 1,
        "mcp__syrus-mcp-sidecar__submit_test_plan" => 1
      )
    end

    it "does not double-count completed MCP tool calls that have a matching started item" do
      summary = ClaudeTranscript.new(input).summary

      expect(summary.tool_call_counts["mcp__syrus-mcp-sidecar__submit_summary"]).to eq(1)
    end
  end
end
