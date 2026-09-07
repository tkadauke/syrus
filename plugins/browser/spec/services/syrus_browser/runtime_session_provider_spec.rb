require "rails_helper"

RSpec.describe SyrusBrowser::RuntimeSessionProvider do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:runtime_session) do
    RuntimeSession.create!(
      repository: repository, chat_session: chat_session,
      workspace_ref: "/workspace/chat-1", provider_key: "browser", display_name: "Browser", state: "running"
    )
  end
  let(:provider) { described_class.new }

  after { Mcp::Tools::AgentPreviewRegistry.reset! }

  describe ".provider_key and .display_name" do
    it "identifies itself as the browser provider" do
      expect(described_class.provider_key).to eq("browser")
      expect(described_class.display_name).to eq("Browser")
    end
  end

  describe ".detect" do
    it "is true when PreviewCommandSource resolves a config for the workspace" do
      allow(PreviewCommandSource).to receive(:new).with("/workspace").and_return(double(resolve: double))

      expect(described_class.detect(repository, workspace_path: "/workspace")).to be_truthy
    end

    it "is false when there is no resolvable preview config" do
      allow(PreviewCommandSource).to receive(:new).with("/workspace").and_return(double(resolve: nil))

      expect(described_class.detect(repository, workspace_path: "/workspace")).to be false
    end

    it "is false when no workspace_path is given" do
      expect(described_class.detect(repository, {})).to be false
    end
  end

  describe ".capabilities" do
    it "matches DOC-17's RuntimeCapability shape" do
      expect(described_class.capabilities(repository, {})).to eq(
        stream: "screenshot",
        input: %w[pointer keyboard],
        inspect: %w[dom],
        build: %w[dev_server hot_reload],
        artifacts: %w[screenshots logs]
      )
    end
  end

  describe "#start_session" do
    it "launches the dev server via the shared PreviewProcessLauncher, keyed by workspace_ref" do
      result = PreviewProcessLauncher::Result.new(pid: 123, port: 3001, url: "http://localhost:3001", reused: false)
      launcher = instance_double(PreviewProcessLauncher)
      allow(PreviewProcessLauncher).to receive(:new).with("/workspace/chat-1").and_return(launcher)
      expect(launcher).to receive(:launch!).with(key: "/workspace/chat-1", port: 3001).and_return(result)

      metadata = provider.start_session("/workspace/chat-1", { port: 3001 })

      expect(metadata).to eq(workspace_ref: "/workspace/chat-1", pid: 123, port: 3001, url: "http://localhost:3001")
    end

    it "defaults to port 3001 when no port is configured" do
      launcher = instance_double(PreviewProcessLauncher)
      allow(PreviewProcessLauncher).to receive(:new).and_return(launcher)
      expect(launcher).to receive(:launch!).with(key: "/workspace/chat-1", port: 3001).and_return(
        PreviewProcessLauncher::Result.new(pid: 424_243, port: 3001, url: "http://localhost:3001", reused: false)
      )

      provider.start_session("/workspace/chat-1", {})
    end
  end

  describe "#build_or_reload" do
    it "kills the existing preview process and starts a fresh one" do
      Mcp::Tools::AgentPreviewRegistry.register(key: runtime_session.workspace_ref, pid: 424_244, port: 3001)
      allow(Mcp::Tools::AgentPreviewRegistry).to receive(:kill).with(runtime_session.workspace_ref).and_call_original

      result = PreviewProcessLauncher::Result.new(pid: 424_245, port: 3001, url: "http://localhost:3001", reused: false)
      launcher = instance_double(PreviewProcessLauncher, launch!: result)
      allow(PreviewProcessLauncher).to receive(:new).and_return(launcher)

      metadata = provider.build_or_reload(runtime_session.id, {})

      expect(Mcp::Tools::AgentPreviewRegistry).to have_received(:kill).with(runtime_session.workspace_ref)
      expect(metadata).to eq(
        workspace_ref: runtime_session.workspace_ref, pid: 424_245, port: 3001, url: "http://localhost:3001"
      )
    end
  end

  describe "#launch" do
    it "raises when there is no running dev server for the session" do
      expect { provider.launch(runtime_session.id, {}) }.to raise_error(described_class::SessionNotFoundError)
    end

    it "navigates the session's browser to the dev server URL via NavigateTool" do
      Mcp::Tools::AgentPreviewRegistry.register(key: runtime_session.workspace_ref, pid: 424_246, port: 4000)
      response = MCP::Tool::Response.new([ { type: "text", text: "navigated" } ])
      expect(SyrusBrowser::NavigateTool).to receive(:call)
        .with(server_context: { runtime_session: runtime_session }, url: "http://127.0.0.1:4000/")
        .and_return(response)

      result = provider.launch(runtime_session.id, {})

      expect(result).to eq(error: false, content: response.content)
    end

    it "honors an explicit path option" do
      Mcp::Tools::AgentPreviewRegistry.register(key: runtime_session.workspace_ref, pid: 424_246, port: 4000)
      response = MCP::Tool::Response.new([])
      expect(SyrusBrowser::NavigateTool).to receive(:call)
        .with(server_context: { runtime_session: runtime_session }, url: "http://127.0.0.1:4000/dashboard")
        .and_return(response)

      provider.launch(runtime_session.id, { path: "/dashboard" })
    end
  end

  describe "#snapshot" do
    it "delegates to ScreenshotTool instead of re-driving Playwright" do
      response = MCP::Tool::Response.new([ { type: "image", data: "abc", mimeType: "image/png" } ])
      expect(SyrusBrowser::ScreenshotTool).to receive(:call)
        .with(server_context: { runtime_session: runtime_session }, target: "e1")
        .and_return(response)

      result = provider.snapshot(runtime_session.id, { target: "e1" })

      expect(result).to eq(error: false, content: response.content)
    end
  end

  describe "#inspect" do
    it "raises NotImplementedError when called with no session_id, like a bare Kernel#inspect" do
      expect { provider.inspect }.to raise_error(NotImplementedError)
    end

    it "delegates to SnapshotTool when given a session_id" do
      response = MCP::Tool::Response.new([ { type: "text", text: "tree" } ])
      expect(SyrusBrowser::SnapshotTool).to receive(:call)
        .with(server_context: { runtime_session: runtime_session })
        .and_return(response)

      result = provider.inspect(runtime_session.id)

      expect(result).to eq(error: false, content: response.content)
    end
  end

  describe "#input" do
    it "reports as not yet supported without raising" do
      result = provider.input(runtime_session.id, { type: "click" })

      expect(result[:error]).to eq("not_yet_supported")
    end
  end

  describe "#logs" do
    it "returns an empty result when no log path is configured" do
      allow(PreviewCommandSource).to receive(:new).with(runtime_session.workspace_ref).and_return(double(resolve: nil))

      expect(provider.logs(runtime_session.id, 0, {})).to eq(entries: [], cursor: 0)
    end

    it "returns lines after the cursor and advances it" do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "development.log")
        File.write(log_path, "line1\nline2\nline3\n")

        source = double(log_paths: [ log_path ])
        allow(PreviewCommandSource).to receive(:new).with(runtime_session.workspace_ref).and_return(double(resolve: source))

        result = provider.logs(runtime_session.id, 1, {})

        expect(result).to eq(entries: %w[line2 line3], cursor: 3)
      end
    end
  end

  describe "#stop_session" do
    it "kills both the browser session and the preview process" do
      Mcp::Tools::AgentPreviewRegistry.register(key: runtime_session.workspace_ref, pid: 424_247, port: 3001)
      allow(SyrusBrowser::SessionRegistry).to receive(:kill)

      expect(provider.stop_session(runtime_session.id)).to be true

      expect(SyrusBrowser::SessionRegistry).to have_received(:kill).with("runtime_session:#{runtime_session.id}")
      expect(Mcp::Tools::AgentPreviewRegistry.get(runtime_session.workspace_ref)).to be_nil
    end
  end
end
