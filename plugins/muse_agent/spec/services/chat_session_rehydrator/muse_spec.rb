require "rails_helper"

RSpec.describe ChatSessionRehydrator::Muse do
  before do
    PluginRecord.find_or_create_by!(name: "muse_agent").update!(enabled: true, default_enabled: false, disableable: true)
  end

  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user, chat_provider: "muse") }

  it "rehydrates canonical chat messages into Muse event JSONL" do
    chat.messages.create!(role: "user", content: { "text" => "hello" })
    chat.messages.create!(role: "assistant", content: [
      { "type" => "text", "text" => "I'll check." },
      { "type" => "thinking", "thinking" => "private" }
    ])
    chat.messages.create!(
      role: "tool_use",
      content: { "type" => "tool_use", "id" => "toolu_1", "name" => "syrus-chat-sidecar.read_job", "input" => { "job_id" => 123 } },
      tool_use_id: "toolu_1",
      tool_name: "syrus-chat-sidecar.read_job"
    )
    chat.messages.create!(
      role: "tool_result",
      content: { "type" => "tool_result", "tool_use_id" => "toolu_1", "content" => { "state" => "open" }, "is_error" => false },
      tool_use_id: "toolu_1",
      tool_name: "syrus-chat-sidecar.read_job"
    )

    jsonl = described_class.new(chat, session_id: "muse-session", cwd: "/tmp/workspace").call
    lines = jsonl.lines.map { |line| JSON.parse(line) }

    expect(lines.map { |line| line.fetch("payload_type") }).to eq([
      "run.session.created",
      "turn.input.user",
      "assistant.message",
      "tool.call",
      "tool.result"
    ])
    expect(lines.first.fetch("payload")).to include("session_id" => "muse-session", "cwd" => "/tmp/workspace")
    expect(lines.third.fetch("payload")).to eq("text" => "I'll check.")
    expect(lines.fourth.fetch("payload")).to include(
      "id" => "toolu_1",
      "server" => "syrus-chat-sidecar",
      "name" => "read_job",
      "input" => { "job_id" => 123 }
    )
    expect(ClaudeTranscript.new(jsonl).summary.session_id).to eq("muse-session")
    expect(ClaudeTranscript.new(jsonl).summary.tool_call_counts).to include("syrus-chat-sidecar.read_job" => 1)
  end
end
