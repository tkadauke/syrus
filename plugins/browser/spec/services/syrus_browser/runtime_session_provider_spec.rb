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
        input: %w[click fill type hover keyboard pointer touch drag drop upload],
        inspect: %w[semantic_dom stable_refs screenshot wait],
        build: %w[dev_server hot_reload],
        artifacts: %w[screenshots logs],
        interaction: %w[click fill hover keyboard pointer touch drag drop upload evaluate],
        viewport: %w[resize emulate]
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
    it "rejects the event when the agent holds no active input lease" do
      result = provider.input(runtime_session.id, { type: "click" })

      expect(result[:error]).to eq("lease_required")
    end

    it "delegates target-based pointer input to the authoritative click tool" do
      browser_session = instance_double(SyrusBrowser::Session, call_tool: { "result" => { "content" => [] } })
      SyrusBrowser::SessionRegistry.session_factory = ->(_key) { browser_session }
      RuntimeControlLease.acquire!(runtime_session: runtime_session, owner: "agent", mode: "input", reason: "click a button")

      result = provider.input(
        runtime_session.id,
        { type: "pointer", action: "click", target: "e3", "_runtime_control_owner" => "agent" }
      )

      expect(result[:error]).to be false
      expect(result[:delivered]).to be true
      expect(browser_session).to have_received(:call_tool).with(
        name: "browser_click",
        arguments: { "target" => "e3" }
      )
    ensure
      SyrusBrowser::SessionRegistry.reset!
    end

    it "delegates target-based text input to Playwright for an operator lease" do
      browser_session = instance_double(SyrusBrowser::Session, call_tool: { "result" => { "content" => [] } })
      SyrusBrowser::SessionRegistry.session_factory = ->(_key) { browser_session }
      RuntimeControlLease.acquire!(
        runtime_session: runtime_session,
        owner: "user",
        owner_ref: "operator:#{user.id}",
        mode: "input",
        reason: "manual input"
      )

      result = provider.input(runtime_session.id, { type: "text", target: "e4", text: "hello", "_runtime_control_owner" => "user" })

      expect(result[:error]).to be false
      expect(browser_session).to have_received(:call_tool).with(name: "browser_type", arguments: { "target" => "e4", "text" => "hello" })
    ensure
      SyrusBrowser::SessionRegistry.reset!
    end

    it "delegates keyboard input to Playwright instead of dispatching a DOM event" do
      browser_session = instance_double(SyrusBrowser::Session, call_tool: { "result" => { "content" => [] } })
      SyrusBrowser::SessionRegistry.session_factory = ->(_key) { browser_session }
      RuntimeControlLease.acquire!(runtime_session: runtime_session, owner: "agent", mode: "input", reason: "submit form")

      result = provider.input(runtime_session.id, { type: "key", key: "Enter", "_runtime_control_owner" => "agent" })

      expect(result[:error]).to be false
      expect(browser_session).to have_received(:call_tool).with(name: "browser_press_key", arguments: { "key" => "Enter" })
    ensure
      SyrusBrowser::SessionRegistry.reset!
    end

    it "delegates the remaining compatibility event types to their authoritative browser tools" do
      browser_session = instance_double(SyrusBrowser::Session, call_tool: { "result" => { "content" => [] } })
      SyrusBrowser::SessionRegistry.session_factory = ->(_key) { browser_session }
      RuntimeControlLease.acquire!(runtime_session: runtime_session, owner: "agent", mode: "input", reason: "interact with the page")

      events_and_calls = [
        [ { type: "hover", target: "e5" }, { name: "browser_hover", arguments: { "target" => "e5" } } ],
        [ { type: "drag", start_ref: "e6", end_ref: "e7" }, { name: "browser_drag", arguments: { "startTarget" => "e6", "endTarget" => "e7" } } ],
        [ { type: "drop", ref: "e8", data: { "text/plain" => "hello" } }, { name: "browser_drop", arguments: { "target" => "e8", "data" => { "text/plain" => "hello" } } } ],
        [ { type: "upload", paths: [ "/tmp/evidence.txt" ] }, { name: "browser_file_upload", arguments: { "paths" => [ "/tmp/evidence.txt" ] } } ]
      ]

      events_and_calls.each do |event, expected_call|
        result = provider.input(runtime_session.id, event.merge("_runtime_control_owner" => "agent"))

        expect(result[:error]).to be false
        expect(browser_session).to have_received(:call_tool).with(expected_call)
      end
    ensure
      SyrusBrowser::SessionRegistry.reset!
    end

    it "rejects coordinate-only pointer input with compatibility guidance after validating the lease" do
      lease = RuntimeControlLease.acquire!(runtime_session: runtime_session, owner: "agent", mode: "input", reason: "click a button")
      allow(runtime_session).to receive(:active_agent_input_lease).and_return(lease)
      expect(lease).to receive(:record_input!).with(hash_including("type" => "pointer", "x" => 40))

      result = provider.input(
        runtime_session,
        { type: "pointer", action: "click", x: 40, y: 60, normalized_x: 0.25, normalized_y: 0.5, "_runtime_control_owner" => "agent" }
      )

      expect(result[:error]).to be true
      expect(result[:content].first[:text]).to include("coordinate-only input is unsupported")
    end

    it "records unsupported input attempts on the active lease before returning an error" do
      lease = RuntimeControlLease.acquire!(runtime_session: runtime_session, owner: "agent", mode: "input", reason: "interact with the page")
      allow(runtime_session).to receive(:active_agent_input_lease).and_return(lease)
      expect(lease).to receive(:record_input!).with(hash_including("type" => "scroll", "delta_y" => 100))

      result = provider.input(runtime_session, { type: "scroll", delta_y: 100, "_runtime_control_owner" => "agent" })

      expect(result[:error]).to be true
      expect(result[:content].first[:text]).to include("unsupported_input_event: scroll")
    end

    it "does not allow an agent input call while only the operator holds the lease" do
      RuntimeControlLease.acquire!(
        runtime_session: runtime_session,
        owner: "user",
        owner_ref: "operator:#{user.id}",
        mode: "input",
        reason: "manual input"
      )

      result = provider.input(runtime_session.id, { type: "pointer", x: 1, y: 1, "_runtime_control_owner" => "agent" })

      expect(result[:error]).to eq("lease_required")
    end
  end

  describe "#logs" do
    it "returns an empty result when no log path is configured" do
      allow(PreviewCommandSource).to receive(:new).with(runtime_session.workspace_ref).and_return(double(resolve: nil))

      expect(provider.logs(runtime_session.id, 0, {})).to eq(entries: [], cursor: 0)
    end

    it "returns lines after the cursor and advances it" do
      Dir.mktmpdir do |dir|
        runtime_session.update!(workspace_ref: dir)
        log_path = File.join(dir, "development.log")
        File.write(log_path, "line1\nline2\nline3\n")

        source = double(log_paths: [ log_path ])
        allow(PreviewCommandSource).to receive(:new).with(runtime_session.workspace_ref).and_return(double(resolve: source))

        result = provider.logs(runtime_session.id, 1, {})

        expect(result).to eq(entries: %w[line2 line3], cursor: 3)
      end
    end

    it "ignores an absolute configured log path outside the workspace" do
      Dir.mktmpdir do |workspace|
        runtime_session.update!(workspace_ref: workspace)
        outside_path = File.join(Dir.tmpdir, "browser-runtime-session-outside.log")
        File.write(outside_path, "outside\n")

        source = double(log_paths: [ outside_path ])
        allow(PreviewCommandSource).to receive(:new).with(runtime_session.workspace_ref).and_return(double(resolve: source))

        expect(provider.logs(runtime_session.id, 0, {})).to eq(entries: [], cursor: 0)
      ensure
        FileUtils.rm_f(outside_path) if outside_path
      end
    end

    it "ignores a configured log path that traverses outside the workspace" do
      Dir.mktmpdir do |parent|
        workspace = File.join(parent, "workspace")
        FileUtils.mkdir_p(workspace)
        runtime_session.update!(workspace_ref: workspace)
        File.write(File.join(parent, "outside.log"), "outside\n")

        source = double(log_paths: [ "../outside.log" ])
        allow(PreviewCommandSource).to receive(:new).with(runtime_session.workspace_ref).and_return(double(resolve: source))

        expect(provider.logs(runtime_session.id, 0, {})).to eq(entries: [], cursor: 0)
      end
    end

    it "ignores an in-workspace symlink that resolves outside the workspace" do
      Dir.mktmpdir do |parent|
        workspace = File.join(parent, "workspace")
        FileUtils.mkdir_p(workspace)
        runtime_session.update!(workspace_ref: workspace)
        outside_path = File.join(parent, "outside.log")
        File.write(outside_path, "outside\n")
        File.symlink(outside_path, File.join(workspace, "leak.log"))

        source = double(log_paths: [ "leak.log" ])
        allow(PreviewCommandSource).to receive(:new).with(runtime_session.workspace_ref).and_return(double(resolve: source))

        expect(provider.logs(runtime_session.id, 0, {})).to eq(entries: [], cursor: 0)
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
