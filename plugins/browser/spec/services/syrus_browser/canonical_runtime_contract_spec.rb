require "rails_helper"

RSpec.describe "Browser canonical Runtime Session contract" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:chat_workspace) { Dir.mktmpdir("browser-chat-contract") }
  let(:run_workspace) { Dir.mktmpdir("browser-run-contract") }
  let(:chat_runtime) do
    RuntimeSession.create!(repository: repository, chat_session: chat_session, workspace_ref: chat_workspace,
      provider_key: "browser", display_name: "Browser", state: "running", primary: true)
  end
  let(:job) { Factories.job(repository: repository, user: user) }
  let(:run) { job.initial_run.tap { |value| value.step.update_column(:kind, "visual_review") } }
  let(:run_runtime) do
    RuntimeSession.create!(repository: repository, job: job, workflow: run.workflow, run: run,
      workspace_ref: run_workspace, provider_key: "browser", display_name: "Browser", state: "running", primary: true)
  end
  let(:provider) { SyrusBrowser::RuntimeSessionProvider.new }
  let(:browser_sessions) { {} }

  before do
    allow(Mcp::Tools).to receive(:run_from_context).with({ run_id: run.id }).and_return(run)
    SyrusBrowser::SessionRegistry.session_factory = lambda do |session_key|
      browser_sessions[session_key] = instance_double(SyrusBrowser::Session,
        call_tool: { "result" => { "content" => [ { "type" => "text", "text" => "ok" } ] } },
        close: nil)
    end
    RuntimeControlLease.acquire!(runtime_session: chat_runtime, owner: "agent", mode: "input", reason: "acceptance flow")
    RuntimeControlLease.acquire!(runtime_session: run_runtime, owner: "agent", mode: "input", reason: "acceptance flow")
  end

  after do
    SyrusBrowser::SessionRegistry.reset!
    Mcp::Tools::AgentPreviewRegistry.reset!
    FileUtils.remove_entry(chat_workspace) if File.exist?(chat_workspace)
    FileUtils.remove_entry(run_workspace) if File.exist?(run_workspace)
  end

  it "executes the same semantic interaction matrix through chat and visual-review Run contexts" do
    matrix = [
      [ "browser_click", { "target" => "submit" }, "browser_click", { "target" => "submit" } ],
      [ "browser_fill", { "target" => "email", "text" => "qa@example.com" }, "browser_type", { "target" => "email", "text" => "qa@example.com" } ],
      [ "browser_hover", { "target" => "help" }, "browser_hover", { "target" => "help" } ],
      [ "browser_press_key", { "key" => "Enter" }, "browser_press_key", { "key" => "Enter" } ],
      [ "browser_drag", { "start_target" => "source", "end_target" => "destination" }, "browser_drag", { "startTarget" => "source", "endTarget" => "destination" } ],
      [ "browser_drop", { "target" => "dropzone", "data" => { "text/plain" => "payload" } }, "browser_drop", { "target" => "dropzone", "data" => { "text/plain" => "payload" } } ],
      [ "browser_file_upload", { "paths" => [ "/tmp/evidence.txt" ] }, "browser_file_upload", { "paths" => [ "/tmp/evidence.txt" ] } ],
      [ "browser_evaluate", { "function" => "() => document.title" }, "browser_evaluate", { "function" => "() => document.title" } ]
    ]

    surfaces.each_value do |surface|
      matrix.each do |tool_name, params, upstream_name, upstream_arguments|
        expect(surface.fetch(:tool_set).handle(tool_name, params, surface.fetch(:context))).not_to be_error
        expect(surface.fetch(:session)).to have_received(:call_tool).with(name: upstream_name, arguments: upstream_arguments)
      end
    end
  end

  it "runs the form acceptance flow against the same Runtime Session in both contexts" do
    launcher = instance_double(Syrus::Host::PreviewProcessLauncher)
    allow(Syrus::Host::PreviewProcessLauncher).to receive(:new).and_return(launcher)
    allow(launcher).to receive(:launch!) do |key:, port:|
      Syrus::Host::PreviewProcessLauncher::Result.new(pid: key == chat_workspace ? 101 : 102,
        port: port, url: "http://127.0.0.1:#{port}", reused: false)
    end

    surfaces.each_value.with_index do |surface, index|
      runtime = surface.fetch(:runtime)
      port = 3101 + index
      File.write(File.join(runtime.workspace_ref, "preview.log"), "form submitted\n")
      source = double(log_paths: [ "preview.log" ])
      allow(Syrus::Host::PreviewCommandSource).to receive(:new).with(runtime.workspace_ref).and_return(double(resolve: source))

      expect(provider.start_session(runtime.workspace_ref, port: port)).to include(port: port)
      Mcp::Tools::AgentPreviewRegistry.register(key: runtime.workspace_ref, pid: 101 + index, port: port)
      provider.launch(runtime.id, path: "/form")
      expect(provider.inspect(runtime.id)[:error]).to be false
      surface.fetch(:tool_set).handle("browser_fill", { "target" => "email", "text" => "qa@example.com" }, surface.fetch(:context))
      surface.fetch(:tool_set).handle("browser_fill", { "target" => "password", "text" => "secret" }, surface.fetch(:context))
      surface.fetch(:tool_set).handle("browser_click", { "target" => "submit" }, surface.fetch(:context))
      surface.fetch(:tool_set).handle("browser_wait_for", { "text" => "Welcome" }, surface.fetch(:context))
      surface.fetch(:tool_set).handle("browser_snapshot", {}, surface.fetch(:context))
      surface.fetch(:tool_set).handle("browser_screenshot", {}, surface.fetch(:context))

      expect(provider.logs(runtime.id, 0, {})[:entries]).to eq([ "form submitted" ])
      expect(provider.stop_session(runtime.id)).to be true
      expect(surface.fetch(:session)).to have_received(:close)
    end
  end

  def surfaces
    chat_key = "runtime_session:#{chat_runtime.id}"
    run_key = "runtime_session:#{run_runtime.id}"
    SyrusBrowser::SessionRegistry.fetch(chat_key)
    SyrusBrowser::SessionRegistry.fetch(run_key)
    {
      chat: { runtime: chat_runtime, tool_set: SyrusBrowser::ChatToolSet.new,
              context: { chat_session: chat_session }, session: browser_sessions.fetch(chat_key) },
      run: { runtime: run_runtime, tool_set: SyrusBrowser::McpToolSet.new,
             context: { run_id: run.id }, session: browser_sessions.fetch(run_key) }
    }
  end
end
