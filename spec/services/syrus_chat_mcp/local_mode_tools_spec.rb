require "rails_helper"

RSpec.describe "Local Mode MCP tools" do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, mode: "local") }
  let(:daemon_session) do
    chat_session.create_local_daemon_session!(
      user: user,
      auth_token: "tok",
      connected_at: Time.current
    )
  end

  def server_with(*tools)
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: tools,
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(server, name, arguments = {})
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def stub_dispatch(tool_name, arguments, result: nil, error: nil)
    call = instance_double(LocalToolCall)
    outcome = result ? { result: result } : { error: error }
    allow(daemon_session).to receive(:dispatch_tool_call!).with(tool_name, arguments).and_return(call)
    allow(call).to receive(:wait_for_result).and_return(outcome)
  end

  shared_examples "disconnected daemon" do |tool_name, arguments = {}|
    it "returns an error when no daemon session exists" do
      server = server_with(described_class)
      response = call_tool(server, tool_name, arguments)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("not connected")
    end

    it "returns an error when the daemon session is not connected" do
      chat_session.create_local_daemon_session!(user: user, auth_token: "tok")
      server = server_with(described_class)

      response = call_tool(server, tool_name, arguments)

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("not connected")
    end
  end

  describe SyrusChatMcp::ReadFileTool do
    include_examples "disconnected daemon", "read_file", { path: "README.md" }

    it "dispatches read_file to the daemon and returns the result" do
      stub_dispatch("read_file", { path: "README.md" }, result: { content: "# Project" })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "read_file", { path: "README.md" })

      expect(response.dig(:result, :isError)).to be_falsey
      payload = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
      expect(payload[:content]).to eq("# Project")
    end
  end

  describe SyrusChatMcp::WriteFileTool do
    include_examples "disconnected daemon", "write_file", { path: "foo.rb", content: "# hello" }

    it "dispatches write_file to the daemon" do
      stub_dispatch("write_file", { path: "app/foo.rb", content: "class Foo; end" }, result: { written: true })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "write_file", { path: "app/foo.rb", content: "class Foo; end" })

      expect(response.dig(:result, :isError)).to be_falsey
    end
  end

  describe SyrusChatMcp::ListFilesTool do
    include_examples "disconnected daemon", "list_files", {}

    it "dispatches list_files to the daemon with a default path" do
      stub_dispatch("list_files", { path: "." }, result: { files: %w[README.md Gemfile] })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "list_files", {})

      expect(response.dig(:result, :isError)).to be_falsey
      payload = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
      expect(payload[:files]).to include("README.md")
    end
  end

  describe SyrusChatMcp::RunCommandTool do
    include_examples "disconnected daemon", "run_command", { command: "echo hi" }

    it "dispatches run_command to the daemon" do
      stub_dispatch("run_command", { command: "bundle exec rspec" }, result: { exit_code: 0, output: "1 example, 0 failures" })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "run_command", { command: "bundle exec rspec" })

      expect(response.dig(:result, :isError)).to be_falsey
      payload = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
      expect(payload[:exit_code]).to eq(0)
    end

    it "propagates daemon-side errors" do
      stub_dispatch("run_command", { command: "bad-cmd" }, error: "command not found")
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "run_command", { command: "bad-cmd" })

      expect(response.dig(:result, :isError)).to be(true)
      expect(response.dig(:result, :content, 0, :text)).to include("command not found")
    end
  end

  describe SyrusChatMcp::GitDiffTool do
    include_examples "disconnected daemon", "git_diff", {}

    it "dispatches git_diff to the daemon" do
      stub_dispatch("git_diff", {}, result: { diff: "diff --git a/foo.rb..." })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "git_diff", {})

      expect(response.dig(:result, :isError)).to be_falsey
      payload = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
      expect(payload[:diff]).to start_with("diff")
    end
  end

  describe SyrusChatMcp::GitStatusTool do
    include_examples "disconnected daemon", "git_status", {}

    it "dispatches git_status to the daemon" do
      stub_dispatch("git_status", {}, result: { status: "On branch main\nnothing to commit" })
      allow(chat_session).to receive(:local_daemon_session).and_return(daemon_session)
      server = server_with(described_class)

      response = call_tool(server, "git_status", {})

      expect(response.dig(:result, :isError)).to be_falsey
      payload = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
      expect(payload[:status]).to include("On branch")
    end
  end
end
