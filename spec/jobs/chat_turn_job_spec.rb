require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe ChatTurnJob do
  let(:user) { Factories.user(claude_oauth_token: "oat-test", github_token: "ghp-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:chat) { ChatSession.create!(repository: repository, user: user) }
  let(:workspace_root) { Pathname.new(Dir.mktmpdir("syrus-chat-workspace")) }
  let(:workspace_path) { workspace_root.join("chat") }
  let(:user_message) { chat.messages.create!(role: "user", content: { text: "What is the plan?" }) }

  it "enqueues chat turns on the chat queue" do
    expect {
      described_class.perform_later(chat.id, user_message.id)
    }.to have_enqueued_job(described_class).with(chat.id, user_message.id).on_queue("chat")
  end

  before do
    ChatTurnJob.agent_runner = nil
    allow(ChatWorkspace).to receive(:path_for).and_call_original
    allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(workspace_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(workspace_path)
  end

  after do
    ChatTurnJob.agent_runner = nil
    FileUtils.rm_rf(workspace_root)
  end

  it "runs a first turn with the chat system prompt, MCP config, no max-turns, and captures output" do
    host_env = {
      "SYRUS_APP_HOST" => "syrus.example.test",
      "SYRUS_ALLOWED_HOSTS" => "syrus.example.test,syrus.internal.test",
      "SYRUS_ASSUME_SSL" => "true",
      "SYRUS_FORCE_SSL" => "true"
    }
    saved = ENV.to_h.slice(*host_env.keys)
    host_env.each { |key, value| ENV[key] = value }
    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      config = JSON.parse(File.read(kwargs[:mcp_config]))
      expect(config.dig("mcpServers", "syrus-chat-sidecar", "command")).to eq(Rails.root.join("bin/syrus-chat-sidecar").to_s)
      expect(config.dig("mcpServers", "syrus-chat-sidecar", "env", "SYRUS_CHAT_SESSION_ID")).to eq(chat.id.to_s)
      expect(config.dig("mcpServers", "syrus-chat-sidecar", "env")).to include(host_env)
      expect(config.dig("mcpServers", "syrus-chat-sidecar", "alwaysLoad")).to eq(true)

      kwargs[:log_sink].call("Here is the shape of it.", kind: "assistant_text")
      kwargs[:log_sink].call(
        "● propose_issue(...)",
        kind: "tool_call",
        tool_name: "propose_issue",
        tool_input: { "slug" => "x", "title" => "T", "body" => "b" }
      )
      kwargs[:log_sink].call(
        "  Issue drafted",
        kind: "tool_result",
        tool_name: "propose_issue",
        tool_result_content: [ { "type" => "text", "text" => "Issue drafted" } ],
        tool_result_error: false
      )
      result_fixture(
        session_id: "chat-session-1",
        transcript_jsonl: "{\"type\":\"system\"}\n",
        cost_usd: 0.004321,
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
      [ "user", "assistant", "tool_use", "tool_result" ]
    )
    expect(chat.reload.cumulative_input_tokens).to eq(12)
    expect(chat.cumulative_output_tokens).to eq(5)
    expect(chat.cumulative_cost).to eq(BigDecimal("0.004321"))
    expect(chat.last_message_at).to be_present

    session = chat.claude_session
    expect(session).to have_attributes(
      resumable: chat,
      provider: "claude",
      session_id: "chat-session-1",
      transcript_jsonl: "{\"type\":\"system\"}\n"
    )
  ensure
    host_env&.keys&.each { |key| ENV.delete(key) }
    saved&.each { |key, value| ENV[key] = value }
  end

  it "includes attached Epic context in the first-turn prompt" do
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "Stabilize the aqueduct",
      description: "Make the water arrive where the Romans insisted it should."
    )
    child = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_title: "Seal the northern arch",
      state: "queued"
    )
    chat.chat_attachments.create!(attachable: epic)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(received[:prompt]).to include("Attached context:")
    expect(received[:prompt]).to include("#{epic.display_number}: Stabilize the aqueduct")
    expect(received[:prompt]).to include("Make the water arrive")
    expect(received[:prompt]).to include("Job ##{child.id}: Seal the northern arch")
    expect(received[:prompt]).to include("Use `read_epic` with id #{epic.id}")
  end

  it "can run a top-level chat before any repository is attached" do
    chat = ChatSession.create!(user: user)
    message = chat.messages.create!(role: "user", content: { text: "Inspect tkadauke/syrus" })
    top_level_path = workspace_root.join("top-level")
    allow(ChatWorkspace).to receive(:path_for).with(chat).and_return(top_level_path)
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(top_level_path)

    received = {}
    ChatTurnJob.agent_runner = ->(**kwargs) {
      received.merge!(kwargs)
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, message.id)

    expect(received[:workspace_path]).to eq(top_level_path.to_s)
    expect(received[:prompt]).to include("Use `attach_repository(slug)`")
  end

  it "preserves existing usage totals when invocation result usage fields are nil" do
    chat.update!(
      cumulative_input_tokens: 10,
      cumulative_output_tokens: 20,
      cumulative_cost_usd: 0.03
    )
    ChatTurnJob.agent_runner = ->(**_) {
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, user_message.id)

    expect(chat.reload.cumulative_input_tokens).to eq(10)
    expect(chat.cumulative_output_tokens).to eq(20)
    expect(chat.cumulative_cost).to eq(BigDecimal("0.03"))
  end

  it "broadcasts chat controls after the agent turn finishes" do
    message = user_message
    ChatTurnJob.agent_runner = ->(**_) {
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    expect(AppEvents).to receive(:broadcast).with(
      user: chat.user,
      type: "updated",
      resource: "chat",
      id: chat.id,
      changed: [ "controls" ],
      payload: include(
        action: "update_controls",
        agent_busy: false,
        stop_requested_at: nil
      )
    )

    described_class.perform_now(chat.id, message.id)
  end

  it "broadcasts chat controls when the agent process starts" do
    message = user_message
    events = []
    allow(AppEvents).to receive(:broadcast) { |**kwargs| events << kwargs }
    ChatTurnJob.agent_runner = ->(workspace_path:, process_started:, **_) {
      process = SpawnedProcess.create!(
        kind: "agent",
        command: "claude --print",
        workdir: workspace_path,
        hostname: "worker-1",
        started_at: Time.current
      )
      process_started.call(process)
      process.update!(finished_at: Time.current, outcome: "succeeded")
      result_fixture(session_id: "chat-session-1", transcript_jsonl: "x")
    }

    described_class.perform_now(chat.id, message.id)

    control_events = events.select { |event| event[:changed] == [ "controls" ] }
    expect(control_events.map { |event| event.dig(:payload, :agent_busy) }).to eq([ true, false ])
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

  it "captures Claude's canonical transcript when the result omits transcript data" do
    Dir.mktmpdir("syrus-chat-home") do |home|
      saved_home = ENV["HOME"]
      ENV["HOME"] = home
      transcript_path = ClaudeSession.canonical_path_for(
        home: home,
        cwd: workspace_path,
        session_id: "chat-session-1"
      )
      FileUtils.mkdir_p(File.dirname(transcript_path))
      File.write(transcript_path, "{\"type\":\"system\"}\n")

      ChatTurnJob.agent_runner = ->(**_) {
        result_fixture(session_id: "chat-session-1")
      }

      described_class.perform_now(chat.id, user_message.id)

      expect(chat.reload.claude_session.transcript_jsonl).to eq("{\"type\":\"system\"}\n")
    ensure
      ENV["HOME"] = saved_home
    end
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
