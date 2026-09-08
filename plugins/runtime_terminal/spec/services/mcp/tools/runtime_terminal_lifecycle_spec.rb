require "rails_helper"

RSpec.describe "runtime_terminal lifecycle through runtime_* MCP tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

  before do
    enable_coding_mode!
    PluginRecord.find_or_create_by!(name: "terminal").update!(enabled: true, disableable: true)
    PluginRecord.find_or_create_by!(name: "runtime_terminal").update!(enabled: true, disableable: true)
    allow(TerminalSessionJob).to receive(:perform_later)
  end

  after { Syrus::PluginRegistry.reset! }

  def parse_tool_response(response)
    JSON.parse(response.content.first[:text])
  end

  it "starts and stops a mapped terminal session without using the terminal HTTP API" do
    Dir.mktmpdir do |workspace|
      allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, repository).and_return(Pathname.new(workspace))

      start_response = Mcp::Tools::RuntimeStartTool.call(
        provider: "cli_tui",
        server_context: { chat_session: chat_session }
      )

      expect(start_response).not_to be_error
      runtime_payload = parse_tool_response(start_response)
      runtime_session = RuntimeSession.find(runtime_payload.fetch("id"))
      terminal_session = RuntimeTerminal::SessionLink.find_by!(runtime_session: runtime_session).terminal_session

      expect(runtime_session).to have_attributes(
        provider_key: "cli_tui",
        display_name: "Terminal",
        state: "running",
        workspace_ref: workspace
      )
      expect(runtime_session.metadata).to include("terminal_session_id" => terminal_session.id)
      expect(terminal_session).to have_attributes(user_id: user.id, workflow_id: nil, working_directory: workspace)
      expect(TerminalSessionJob).to have_received(:perform_later).with(terminal_session.id)

      stop_response = Mcp::Tools::RuntimeStopTool.call(
        session_id: runtime_session.id,
        server_context: { chat_session: chat_session }
      )

      expect(stop_response).not_to be_error
      expect(parse_tool_response(stop_response).fetch("state")).to eq("stopped")
      expect(runtime_session.reload.state).to eq("stopped")
      expect(terminal_session.reload.outcome).to eq("killed")
      expect(terminal_session.finished_at).to be_present
    end
  end

  it "routes runtime_inspect and runtime_input through the terminal relay with lease enforcement" do
    relay = RuntimeTerminalFakeRelay.new(replay: "ready\n")

    Dir.mktmpdir do |workspace|
      allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, repository).and_return(Pathname.new(workspace))

      start_response = Mcp::Tools::RuntimeStartTool.call(
        provider: "cli_tui",
        server_context: { chat_session: chat_session }
      )
      runtime_session = RuntimeSession.find(parse_tool_response(start_response).fetch("id"))
      terminal_session = RuntimeTerminal::SessionLink.find_by!(runtime_session: runtime_session).terminal_session
      terminal_session.update!(relay_address: relay.address)

      inspect_response = Mcp::Tools::RuntimeInspectTool.call(
        session_id: runtime_session.id,
        server_context: { chat_session: chat_session }
      )

      expect(parse_tool_response(inspect_response)).to include(
        "kind" => "terminal_scrollback",
        "scrollback" => "ready\n",
        "bytes" => 6
      )

      rejected_input = Mcp::Tools::RuntimeInputTool.call(
        session_id: runtime_session.id,
        event: { type: "stdin", data: "whoami\n" },
        server_context: { chat_session: chat_session }
      )
      expect(parse_tool_response(rejected_input)).to include("error" => "lease_required")

      RuntimeControlLease.acquire!(runtime_session: runtime_session, owner: "agent", mode: "input", reason: "typing")
      accepted_input = Mcp::Tools::RuntimeInputTool.call(
        session_id: runtime_session.id,
        event: { type: "stdin", data: "whoami\n" },
        server_context: { chat_session: chat_session }
      )

      expect(parse_tool_response(accepted_input)).to eq("delivered" => true)
      expect(relay.next_control).to eq("type" => "input", "data" => "whoami\n")
    end
  ensure
    RuntimeTerminal::Provider.reset_relay_clients!
    relay&.stop
  end
end
