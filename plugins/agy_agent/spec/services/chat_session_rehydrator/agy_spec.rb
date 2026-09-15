require "rails_helper"

RSpec.describe ChatSessionRehydrator::Agy do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:session) { ChatSession.create!(user: user) }

  before { allow(AppEvents).to receive(:broadcast) }

  def create_message!(role:, content:, tool_name: nil, tool_use_id: nil)
    session.messages.create!(role: role, content: content, tool_name: tool_name, tool_use_id: tool_use_id)
  end

  def parsed_lines(jsonl)
    jsonl.lines.map { |line| JSON.parse(line) }
  end

  def agy_fixture(name)
    Rails.root.join("plugins/agy_agent/spec/fixtures/files/agy_transcripts/#{name}").read
  end

  it "emits an init line when a conversation id is supplied" do
    lines = parsed_lines(described_class.new(session, session_id: "agy-conv-1").call)

    expect(lines.first).to include("event" => "init", "conversation_id" => "agy-conv-1")
  end

  it "normalizes user and assistant chat messages to Antigravity stream JSONL" do
    create_message!(role: "user", content: { "text" => "Hello." })
    create_message!(role: "assistant", content: [
      { "type" => "thinking", "thinking" => "private" },
      { "type" => "text", "text" => "Hi there." }
    ])

    lines = parsed_lines(described_class.new(session, session_id: "agy-conv-1").call)

    expect(lines).to include(
      include("event" => "user", "message" => { "content" => "Hello." }),
      include("event" => "step_update", "message" => { "role" => "assistant", "content" => "Hi there." })
    )
    expect(lines.to_json).not_to include("private")
  end

  it "normalizes MCP tool use and results with Antigravity tool labels" do
    create_message!(
      role: "tool_use",
      tool_name: "mcp__syrus-chat-sidecar__read_live_state",
      tool_use_id: "tool-1",
      content: {
        "type" => "tool_use",
        "id" => "tool-1",
        "name" => "mcp__syrus-chat-sidecar__read_live_state",
        "input" => { "scope" => "chat" }
      }
    )
    create_message!(
      role: "tool_result",
      tool_name: "mcp__syrus-chat-sidecar__read_live_state",
      tool_use_id: "tool-1",
      content: {
        "type" => "tool_result",
        "tool_use_id" => "tool-1",
        "content" => "ok",
        "is_error" => false
      }
    )

    lines = parsed_lines(described_class.new(session, session_id: "agy-conv-1").call)
    tool_call = lines.find { |line| line.dig("tool_call", "id") == "tool-1" }
    tool_result = lines.find { |line| line.dig("tool_result", "id") == "tool-1" }

    expect(tool_call.dig("tool_call", "name")).to eq("mcp(syrus-chat-sidecar/read_live_state)")
    expect(tool_call.dig("tool_call", "input")).to eq("scope" => "chat")
    expect(tool_result.dig("tool_result", "name")).to eq("mcp(syrus-chat-sidecar/read_live_state)")
    expect(tool_result.dig("tool_result", "content")).to eq("ok")
    expect(tool_result.dig("tool_result", "is_error")).to eq(false)
  end

  it "parses saved Antigravity transcript JSONL and skips malformed lines gracefully" do
    jsonl = agy_fixture("chat_turn_with_malformed.jsonl")

    events = ClaudeTranscript.new(jsonl).events.to_a

    expect(events.map(&:kind)).to include(:system_init, :user_prompt, :assistant_text, :tool_use, :tool_result, :result)
    expect(events.find { |event| event.kind == :system_init }.data[:session_id]).to eq("agy-conv-1")
    expect(events.find { |event| event.kind == :tool_use }.data).to include(
      name: "mcp__syrus-chat-sidecar__read_live_state",
      id: "tool-1"
    )
    expect(events.find { |event| event.kind == :result }.data[:usage]).to include("total_tokens" => 12)
  end
end
