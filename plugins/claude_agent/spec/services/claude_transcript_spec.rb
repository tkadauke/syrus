require "rails_helper"

RSpec.describe ClaudeTranscript do
  # Build a minimal JSONL string from line hashes — claude-code's
  # on-disk format is one JSON object per line. Helper keeps tests
  # readable.
  def jsonl(*lines)
    lines.map(&:to_json).join("\n") + "\n"
  end

  describe "#events" do
    it "extracts a system_init event with model + cwd + tools" do
      input = jsonl(
        { "type" => "system", "subtype" => "init", "model" => "claude-sonnet-4-6",
          "cwd" => "/syrus-home/.syrus/workflows/42",
          "tools" => [ "Bash", "Read", "mcp__syrus__submit_summary" ],
          "session_id" => "abc-123", "timestamp" => "2026-05-04T00:00:00Z" }
      )
      events = described_class.new(input).events.to_a
      expect(events.size).to eq(1)
      expect(events.first.kind).to eq(:system_init)
      expect(events.first.data[:model]).to eq("claude-sonnet-4-6")
      expect(events.first.data[:tools]).to include("mcp__syrus__submit_summary")
      expect(events.first.data[:session_id]).to eq("abc-123")
    end

    it "extracts user_prompt from a string-content user event" do
      input = jsonl(
        { "type" => "user",
          "message" => { "role" => "user", "content" => "Implement the greeting helper." } }
      )
      events = described_class.new(input).events.to_a
      expect(events.size).to eq(1)
      expect(events.first.kind).to eq(:user_prompt)
      expect(events.first.data[:text]).to eq("Implement the greeting helper.")
    end

    it "extracts one tool_result event per result block in an array-content user event" do
      input = jsonl(
        { "type" => "user", "message" => { "role" => "user", "content" => [
          { "type" => "tool_result", "tool_use_id" => "t1", "content" => "ok" },
          { "type" => "tool_result", "tool_use_id" => "t2", "content" => "fail", "is_error" => true }
        ] } }
      )
      events = described_class.new(input).events.to_a
      expect(events.size).to eq(2)
      expect(events.map(&:kind)).to eq([ :tool_result, :tool_result ])
      expect(events.first.data[:tool_use_id]).to eq("t1")
      expect(events.first.data[:error]).to be false
      expect(events.last.data[:tool_use_id]).to eq("t2")
      expect(events.last.data[:error]).to be true
    end

    it "splits a mixed-content assistant event into one event per text/tool_use block" do
      input = jsonl(
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "text", "text" => "Reading the file…" },
          { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/foo" }, "id" => "u1" },
          { "type" => "text", "text" => "And again." },
          { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "ls" }, "id" => "u2" }
        ] } }
      )
      events = described_class.new(input).events.to_a
      expect(events.map(&:kind)).to eq([ :assistant_text, :tool_use, :assistant_text, :tool_use ])
      expect(events[1].data[:name]).to eq("Read")
      expect(events[3].data[:name]).to eq("Bash")
    end

    it "tags assistant/tool_use events from a sidechain (subagent) line with sidechain + parent_tool_use_id" do
      input = jsonl(
        { "type" => "assistant", "isSidechain" => true, "parentToolUseId" => "toolu_agent1",
          "message" => { "content" => [
            { "type" => "text", "text" => "Looking around…" },
            { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/foo" }, "id" => "sub1" }
          ] } }
      )
      events = described_class.new(input).events.to_a
      expect(events.map(&:kind)).to eq([ :assistant_text, :tool_use ])
      events.each do |event|
        expect(event.data[:sidechain]).to be true
        expect(event.data[:parent_tool_use_id]).to eq("toolu_agent1")
      end
    end

    it "tags user_prompt/tool_result events from a sidechain line with sidechain + parent_tool_use_id" do
      input = jsonl(
        { "type" => "user", "isSidechain" => true, "parentToolUseId" => "toolu_agent1",
          "message" => { "content" => [
            { "type" => "tool_result", "tool_use_id" => "sub1", "content" => "ok" }
          ] } }
      )
      events = described_class.new(input).events.to_a
      expect(events.first.kind).to eq(:tool_result)
      expect(events.first.data[:sidechain]).to be true
      expect(events.first.data[:parent_tool_use_id]).to eq("toolu_agent1")
    end

    it "marks non-sidechain (top-level) events as sidechain: false with no parent_tool_use_id" do
      input = jsonl(
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "text", "text" => "Top-level text" }
        ] } }
      )
      events = described_class.new(input).events.to_a
      expect(events.first.data[:sidechain]).to be false
      expect(events.first.data[:parent_tool_use_id]).to be_nil
    end

    it "extracts a result event with turns + cost + exit reason" do
      input = jsonl(
        { "type" => "result", "subtype" => "success", "num_turns" => 12,
          "duration_ms" => 30_000, "total_cost_usd" => 0.42, "is_error" => false }
      )
      events = described_class.new(input).events.to_a
      expect(events.size).to eq(1)
      expect(events.first.kind).to eq(:result)
      expect(events.first.data[:turns]).to eq(12)
      expect(events.first.data[:cost_usd]).to eq(0.42)
      expect(events.first.data[:subtype]).to eq("success")
    end

    it "skips unknown event types as :other (doesn't drop them entirely)" do
      input = jsonl({ "type" => "queue-operation", "operation" => "enqueue" })
      events = described_class.new(input).events.to_a
      expect(events.first.kind).to eq(:other)
    end

    it "skips lines that don't parse as JSON (resilient to malformed input)" do
      input = "{\"type\":\"system\",\"subtype\":\"init\"}\nnot json\n{\"type\":\"result\"}\n"
      kinds = described_class.new(input).events.map(&:kind)
      expect(kinds).to eq([ :system_init, :result ])
    end

    it "skips malformed JSON fragments that are not event objects" do
      input = "[1,2,3]\n{\"type\":\"assistant\",\"message\":\"not a hash\"}\n{\"type\":\"result\",\"subtype\":\"success\"}\n"
      events = described_class.new(input).events.to_a
      expect(events.map(&:kind)).to eq([ :result ])
    end

    it "handles an empty / nil input without raising" do
      expect(described_class.new("").events.to_a).to eq([])
      expect(described_class.new(nil).events.to_a).to eq([])
    end
  end

  describe "#summary" do
    it "computes turn / tool / cost rollups + flags MCP tool usage" do
      input = jsonl(
        { "type" => "system", "subtype" => "init", "model" => "claude-sonnet-4-6",
          "cwd" => "/x", "tools" => [ "Bash", "mcp__syrus__submit_summary" ],
          "session_id" => "s1" },
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "tool_use", "name" => "Bash", "input" => {}, "id" => "u1" }
        ] } },
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "tool_use", "name" => "Bash", "input" => {}, "id" => "u2" }
        ] } },
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "tool_use", "name" => "mcp__syrus__submit_summary", "input" => {}, "id" => "u3" }
        ] } },
        { "type" => "result", "subtype" => "success", "num_turns" => 3,
          "duration_ms" => 1500, "total_cost_usd" => 0.05, "is_error" => false }
      )
      summary = described_class.new(input).summary
      expect(summary.total_turns).to eq(3)
      expect(summary.total_tool_calls).to eq(3)
      expect(summary.total_cost_usd).to eq(0.05)
      expect(summary.exit_reason).to eq("success")
      expect(summary.tool_call_counts).to eq("Bash" => 2, "mcp__syrus__submit_summary" => 1)
      expect(summary.mcp_tool_called?).to be true
      expect(summary.available_tools_at_init).to include("mcp__syrus__submit_summary")
      expect(summary.session_id).to eq("s1")
      expect(summary.model).to eq("claude-sonnet-4-6")
    end

    it "reports mcp_tool_called? false when no mcp__ tool was invoked" do
      input = jsonl(
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "tool_use", "name" => "Bash", "input" => {}, "id" => "u1" }
        ] } }
      )
      expect(described_class.new(input).summary.mcp_tool_called?).to be false
    end

    it "doesn't blow up when there's no result event (truncated transcript)" do
      input = jsonl({ "type" => "user", "message" => { "role" => "user", "content" => "hi" } })
      summary = described_class.new(input).summary
      expect(summary.total_turns).to be_nil
      expect(summary.exit_reason).to be_nil
    end
  end

end
