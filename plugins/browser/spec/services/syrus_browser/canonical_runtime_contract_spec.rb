require "rails_helper"
require "socket"

RSpec.describe "Browser canonical Runtime Session contract" do
  class FormFixtureServer
    attr_reader :port

    def initialize(log_path)
      @log_path = log_path
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
    end

    def stop
      @server.close
      @thread.join(2)
    rescue IOError
      nil
    end

    private

    def serve
      loop { handle(@server.accept) }
    rescue IOError, Errno::EBADF
      nil
    end

    def handle(socket)
      request = socket.gets.to_s
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end
      socket.read(headers.fetch("content-length", "0").to_i)
      path = request.split[1]
      if path == "/log"
        File.open(@log_path, "a") { |file| file.puts("form submitted") }
        respond(socket, "logged", "text/plain")
      else
        respond(socket, form_html, "text/html")
      end
    ensure
      socket.close
    end

    def respond(socket, body, content_type)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end

    def form_html
      <<~HTML
        <!doctype html><html><body>
          <label>Email <input aria-label="Email" type="email"></label>
          <label>Password <input aria-label="Password" type="password"></label>
          <label>Name <input aria-label="Name" type="text"></label>
          <label>Notes <textarea aria-label="Notes"></textarea></label>
          <div aria-label="Biography" contenteditable="true"></div>
          <label>Controlled <input aria-label="Controlled" id="controlled"></label>
          <button type="button">Submit</button><div role="status"></div>
          <script>
            const controlled = document.querySelector('#controlled');
            controlled.addEventListener('input', (event) => controlled.dataset.state = event.target.value);
            document.querySelector('button').addEventListener('click', async () => {
              const values = [...document.querySelectorAll('input,textarea')].map((field) => field.value);
              const biography = document.querySelector('[contenteditable]').textContent;
              if (values.every(Boolean) && biography) {
                await fetch('/log', {method: 'POST', body: JSON.stringify({values, biography})});
                document.querySelector('[role=status]').textContent = 'Welcome';
              }
            });
          </script>
        </body></html>
      HTML
    end
  end

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
    allow(Feature).to receive(:coding_mode_enabled?).and_return(true)
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
      [
        { type: "pointer", action: "click", target: "submit" },
        { type: "touch", action: "click", target: "submit" },
        { type: "text", target: "email", text: "qa@example.com" },
        { type: "key", key: "Tab" }
      ].each do |event|
        response = Mcp::Tools::RuntimeInputTool.call(
          session_id: surface.fetch(:runtime).id, event: event, server_context: surface.fetch(:context)
        )
        expect(response).not_to be_error
        expect(JSON.parse(response.content.first[:text], symbolize_names: true)).to include(error: false, delivered: true)
      end
    end
  end

  it "drives a real form and captures evidence through the same Runtime Session in both contexts" do
    # This contract genuinely needs a real browser: the playwright-mcp binary
    # and the Chromium it drives. Worker images ship both; a developer machine
    # usually has neither. Say so instead of failing with a spawn error that
    # reads like a regression.
    skip_without_real_browser_runtime!
    SyrusBrowser::SessionRegistry.reset!
    SyrusBrowser::SessionRegistry.session_factory = ->(session_key) { SyrusBrowser::Session.spawn_stdio(session_key) }
    launcher = instance_double(Syrus::Host::PreviewProcessLauncher)
    allow(Syrus::Host::PreviewProcessLauncher).to receive(:new).and_return(launcher)

    real_surfaces.each_value.with_index do |surface, index|
      runtime = surface.fetch(:runtime)
      log_path = File.join(runtime.workspace_ref, "preview.log")
      server = FormFixtureServer.new(log_path)
      allow(launcher).to receive(:launch!).with(key: runtime.workspace_ref, port: server.port).and_return(
        Syrus::Host::PreviewProcessLauncher::Result.new(pid: 101 + index, port: server.port,
          url: "http://127.0.0.1:#{server.port}", reused: false)
      )
      source = double(log_paths: [ "preview.log" ])
      allow(Syrus::Host::PreviewCommandSource).to receive(:new).with(runtime.workspace_ref).and_return(double(resolve: source))

      expect(provider.start_session(runtime.workspace_ref, port: server.port)).to include(port: server.port)
      Mcp::Tools::AgentPreviewRegistry.register(key: runtime.workspace_ref, pid: 101 + index, port: server.port)
      provider.launch(runtime.id, path: "/form")
      snapshot = provider.inspect(runtime.id)
      refs = refs_from(snapshot.fetch(:content))

      values = {
        "Email" => "qa@example.com", "Password" => "secret", "Name" => "QA",
        "Notes" => "real textarea", "Biography" => "content editable", "Controlled" => "framework state"
      }
      values.each do |label, text|
        response = surface.fetch(:tool_set).handle("browser_fill", { "target" => refs.fetch(label), "text" => text }, surface.fetch(:context))
        expect(response).not_to be_error
      end
      expect(surface.fetch(:tool_set).handle("browser_click", { "target" => refs.fetch("Submit") }, surface.fetch(:context))).not_to be_error
      expect(surface.fetch(:tool_set).handle("browser_wait_for", { "text" => "Welcome" }, surface.fetch(:context))).not_to be_error

      state = surface.fetch(:tool_set).handle("browser_evaluate", {
        "function" => "() => JSON.stringify({email:document.querySelector('[aria-label=Email]').value,password:document.querySelector('[aria-label=Password]').value,name:document.querySelector('[aria-label=Name]').value,notes:document.querySelector('[aria-label=Notes]').value,biography:document.querySelector('[aria-label=Biography]').textContent,controlled:document.querySelector('#controlled').dataset.state})"
      }, surface.fetch(:context))
      expect(state.content.map { |block| block[:text] }.compact.join).to include(*values.values)

      semantic = surface.fetch(:tool_set).handle("browser_snapshot", {}, surface.fetch(:context))
      visual = surface.fetch(:tool_set).handle("browser_screenshot", {}, surface.fetch(:context))
      expect(semantic).not_to be_error
      expect(semantic.content.map { |block| block[:text] }.compact.join).to include("Welcome")
      expect(visual.content).to include(include(type: "image"))

      expect(provider.logs(runtime.id, 0, {})[:entries]).to eq([ "form submitted" ])
      expect_evidence_for(surface.fetch(:kind), runtime)
      expect(provider.stop_session(runtime.id)).to be true
    ensure
      server&.stop
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

  def skip_without_real_browser_runtime!
    command = SyrusBrowser::Session::DEFAULT_COMMAND
    on_path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
      path = File.join(dir, command)
      File.file?(path) && File.executable?(path)
    end
    skip("requires the #{command} binary on PATH (real browser contract; not installed on this host)") unless on_path

    browser = SyrusBrowser::Session.browser_executable_path
    skip("requires a Chromium executable at #{browser} (set SYRUS_BROWSER_EXECUTABLE_PATH)") unless File.executable?(browser)
  end

  def real_surfaces
    {
      chat: { kind: :chat, runtime: chat_runtime, tool_set: SyrusBrowser::ChatToolSet.new,
              context: { chat_session: chat_session } },
      run: { kind: :run, runtime: run_runtime, tool_set: SyrusBrowser::McpToolSet.new,
             context: { run_id: run.id } }
    }
  end

  def refs_from(content)
    text = content.map { |block| block[:text] }.compact.join("\n")
    %w[Email Password Name Notes Biography Controlled Submit].to_h do |label|
      [ label, text.match(/#{label.inspect}\s+\[ref=(?<ref>[^\]]+)\]/)&.[](:ref) ||
        raise("missing #{label} ref in snapshot: #{text}") ]
    end
  end

  def expect_evidence_for(kind, runtime)
    if kind == :chat
      expect(runtime.reload.latest_frame_at).to be_present
      expect(chat_session.chat_attachments.reload).not_to be_empty
    else
      evidence = run.workflow.visual_evidences.where(run: run).last
      expect(evidence).to be_present
      expect(evidence.image).to be_attached
    end
  end
end
