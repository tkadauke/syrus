require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe ChatTurnJob do
  let(:user) { Factories.user(claude_oauth_token: "oat-test", github_token: "ghp-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:chat) { ChatSession.create!(repository: repository, user: user) }
  let(:workspace_root) { Pathname.new(Dir.mktmpdir("syrus-chat-workspace")) }
  let(:workspace_path) { workspace_root.join("repo") }
  let(:user_message) { chat.messages.create!(role: "user", content: { text: "What is the plan?" }) }

  before do
    ChatTurnJob.agent_runner = nil
    allow(ChatWorkspace).to receive(:path_for).with(repository).and_return(workspace_path)
    allow(ChatWorkspace).to receive(:ensure!).with(repository).and_return(workspace_path)
  end

  after do
    ChatTurnJob.agent_runner = nil
    FileUtils.rm_rf(workspace_root)
  end

  it "runs a first turn with the chat system prompt, MCP config, no max-turns, and captures output" do
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      config = JSON.parse(File.read(kwargs[:mcp_config]))
      expect(config.dig("mcpServers", "syrus-chat-sidecar", "command")).to eq(Rails.root.join("bin/syrus-chat-sidecar").to_s)
      expect(config.dig("mcpServers", "syrus-chat-sidecar", "env", "SYRUS_CHAT_SESSION_ID")).to eq(chat.id.to_s)
      expect(config.dig("mcpServers", "syrus-chat-sidecar", "alwaysLoad")).to eq(true)

      kwargs[:log_sink].call("Here is the shape of it.", kind: "assistant_text")
      kwargs[:log_sink].call("● propose_issue(...)", kind: "tool_call")
      kwargs[:log_sink].call("  Issue drafted", kind: "tool_result")
      result_fixture(
        session_id: "chat-session-1",
        transcript_jsonl: "{\"type\":\"system\"}\n",
        input_tokens: 12,
        output_tokens: 5
      )
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:workspace_path]).to eq(workspace_path.to_s)
    expect(received[:prompt]).to include("embedded research and planning assistant")
    expect(received[:prompt]).to include("What is the plan?")
    expect(received[:resume_session_id]).to be_nil
    expect(received[:max_turns]).to be_nil

    expect(chat.messages.order(:created_at).pluck(:role)).to eq(
      [ "user", "system", "system", "assistant", "tool_use", "tool_result" ]
    )
    expect(chat.reload.cumulative_input_tokens).to eq(12)
    expect(chat.cumulative_output_tokens).to eq(5)
    expect(chat.last_message_at).to be_present

    session = chat.claude_session
    expect(session).to have_attributes(
      resumable: chat,
      provider: "claude",
      session_id: "chat-session-1",
      transcript_jsonl: "{\"type\":\"system\"}\n"
    )
  end

  it "resumes the existing Claude session after the first turn and omits the system prompt" do
    chat.create_claude_session!(
      provider: "claude",
      session_id: "chat-session-1",
      transcript_jsonl: "old"
    )
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-2", transcript_jsonl: "new")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:resume_session_id]).to eq("chat-session-1")
    expect(received[:prompt]).to eq("What is the plan?")
    expect(chat.reload.claude_session).to have_attributes(
      session_id: "chat-session-2",
      transcript_jsonl: "new"
    )
  end

  it "writes a system message and skips the agent when Claude credentials are missing" do
    user.update!(claude_oauth_token: nil)
    called = false
    ChatTurnJob.agent_runner = ->(**_) { called = true }

    described_class.perform_now(chat.id, user_message.id)

    expect(called).to eq(false)
    expect(chat.messages.last).to have_attributes(
      role: "system",
      content: include("text" => match(/Claude credentials are missing/))
    )
  end

  it "polls stop_requested_at between stream events and records cancellation" do
    ChatTurnJob.agent_runner = ->(log_sink:, stop_requested:, **_) {
      log_sink.call("Working...", kind: "assistant_text")
      chat.update!(stop_requested_at: 1.second.from_now)

      expect(stop_requested.call).to eq(true)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(chat.messages.order(:created_at).pluck(:role, :content)).to include(
      [ "system", { "text" => "Cancelled by operator." } ]
    )
  end

  it "clears stale stop requests at turn start" do
    chat.update!(stop_requested_at: 5.minutes.ago)
    ChatTurnJob.agent_runner = ->(stop_requested:, **_) {
      expect(stop_requested.call).to eq(false)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(chat.reload.stop_requested_at).to be_nil
  end

  def result_fixture(**overrides)
    attrs = {
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: nil,
      session_id: nil
    }.merge(overrides)
    AgentInvocation::Result.new(**attrs)
  end
end
