require "rails_helper"

RSpec.describe "runtime_* MCP tools (DOC-17)" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

  def tool_classes
    [
      Mcp::Tools::RuntimeListSessionsTool,
      Mcp::Tools::RuntimeStartTool,
      Mcp::Tools::RuntimeStatusTool,
      Mcp::Tools::RuntimeBuildOrReloadTool,
      Mcp::Tools::RuntimeLaunchTool,
      Mcp::Tools::RuntimeSnapshotTool,
      Mcp::Tools::RuntimeInspectTool,
      Mcp::Tools::RuntimeLogsTool,
      Mcp::Tools::RuntimeAcquireControlTool,
      Mcp::Tools::RuntimeReleaseControlTool,
      Mcp::Tools::RuntimeInputTool,
      Mcp::Tools::RuntimeCaptureArtifactTool,
      Mcp::Tools::RuntimeStopTool
    ]
  end

  before do
    enable_coding_mode!
    register_stub_runtime_provider!
  end

  after { Syrus::PluginRegistry.reset! }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: tool_classes,
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, **arguments)
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "registers every DOC-17 generic tool under its documented name" do
    expect(tool_classes.map(&:tool_name)).to contain_exactly(
      "runtime_list_sessions", "runtime_start", "runtime_status", "runtime_build_or_reload",
      "runtime_launch", "runtime_snapshot", "runtime_inspect", "runtime_logs",
      "runtime_acquire_control", "runtime_release_control", "runtime_input",
      "runtime_capture_artifact", "runtime_stop"
    )
  end

  it "walks the full session lifecycle: start -> build/reload -> snapshot -> acquire lease -> input -> release lease -> stop" do
    Dir.mktmpdir do |workspace|
      allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, repository).and_return(Pathname.new(workspace))

      listed_before = call_tool("runtime_list_sessions")
      expect(payload(listed_before)[:sessions]).to eq([])

      start = call_tool("runtime_start", provider: "stub", name: "Dev Server")
      expect(start.dig(:result, :isError)).to be_falsey
      started = payload(start)
      expect(started).to include(state: "running", primary: true, display_name: "Dev Server")
      session_id = started[:id]

      status = call_tool("runtime_status", session_id: session_id)
      expect(payload(status)[:state]).to eq("running")

      reload = call_tool("runtime_build_or_reload", session_id: session_id)
      expect(reload.dig(:result, :isError)).to be_falsey
      expect(payload(reload)).to eq(reloaded: true)

      snapshot = call_tool("runtime_snapshot", session_id: session_id)
      expect(payload(snapshot)).to eq(snapshot: true, options: {})

      inspect_result = call_tool("runtime_inspect", session_id: session_id)
      expect(payload(inspect_result)).to eq(tree: [])

      rejected_input = call_tool("runtime_input", session_id: session_id, event: { type: "click" })
      expect(payload(rejected_input)).to eq(error: "lease_required")

      acquire = call_tool("runtime_acquire_control", session_id: session_id, mode: "input", reason: "click a button")
      expect(acquire.dig(:result, :isError)).to be_falsey
      lease = payload(acquire)
      expect(lease).to include(owner: "agent", mode: "input", state: "active")

      accepted_input = call_tool("runtime_input", session_id: session_id, event: { type: "click", target: "e1" })
      expect(payload(accepted_input)).to eq(delivered: { type: "click", target: "e1" })

      capture = call_tool("runtime_capture_artifact", session_id: session_id, artifact_type: "screenshot")
      expect(payload(capture)).to eq(snapshot: true, options: { artifact_type: "screenshot" })

      release = call_tool("runtime_release_control", session_id: session_id)
      released = payload(release)[:released]
      expect(released.size).to eq(1)
      expect(released.first[:id]).to eq(lease[:id])

      stop = call_tool("runtime_stop", session_id: session_id)
      expect(payload(stop)[:state]).to eq("stopped")

      final_status = call_tool("runtime_status", session_id: session_id)
      expect(payload(final_status)[:state]).to eq("stopped")

      listed_after = call_tool("runtime_list_sessions")
      expect(payload(listed_after)[:sessions].map { |s| s[:id] }).to eq([ session_id ])
    end
  end

  it "keeps runtime_* tools unavailable outside Coding Mode" do
    planning_chat = ChatSession.create!(user: user, repository: repository, mode: "planning")
    context = McpToolContext.from_chat_session(planning_chat)

    tool_names = McpToolRegistry.tools_for_context(context, surface: :chat, tier: :essential).map { |t| McpToolRegistry.tool_name_for(t) }

    expect(tool_names).not_to include(*%w[runtime_list_sessions runtime_start runtime_status runtime_input runtime_stop])
  end

  it "exposes runtime_* tools to a Coding Mode chat when the feature is enabled" do
    context = McpToolContext.from_chat_session(chat_session)

    tool_names = McpToolRegistry.tools_for_context(context, surface: :chat, tier: :essential).map { |t| McpToolRegistry.tool_name_for(t) }

    expect(tool_names).to include(*%w[runtime_list_sessions runtime_start runtime_status runtime_input runtime_stop])
  end
end
