require "rails_helper"
require "tmpdir"

RSpec.describe Android::EmulatorRuntimeSessionProvider do
  class AndroidRuntimeFakeRunner
    attr_reader :captures, :spawns, :killed_pids

    def initialize
      @captures = []
      @spawns = []
      @killed_pids = []
      @responses = []
    end

    def enqueue(match, stdout: "", stderr: "", status: 0)
      @responses << [ match, Android::EmulatorRuntimeSessionProvider::CommandResult.new(stdout: stdout, stderr: stderr, status: status) ]
    end

    def capture(argv, env:, chdir: nil, timeout: 60, stdin_data: nil)
      @captures << { argv: argv, env: env, chdir: chdir, timeout: timeout, stdin_data: stdin_data }
      index = @responses.index { |(match, _)| match.call(argv) }
      return @responses.delete_at(index).last if index

      Android::EmulatorRuntimeSessionProvider::CommandResult.new(stdout: "", stderr: "", status: 0)
    end

    def spawn(argv, env:, chdir: nil, out: File::NULL, err: File::NULL)
      @spawns << { argv: argv, env: env, chdir: chdir, out: out, err: err }
      Android::EmulatorRuntimeSessionProvider::ProcessHandle.new(pid: 12_345)
    end

    def kill(pid)
      @killed_pids << pid
    end
  end

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }
  let(:runner) { AndroidRuntimeFakeRunner.new }
  let(:provider) { described_class.new }

  around do |ex|
    Dir.mktmpdir("syrus-android-runtime") do |dir|
      @workspace = dir
      ex.run
    end
  end

  before do
    described_class.command_runner = runner
    allow(Android::ToolchainDiagnostic).to receive(:call).and_return(toolchain_ready)
  end

  after do
    described_class.reset_command_runner!
    Syrus::PluginRegistry.reset!
  end

  def runtime_session(**attrs)
    RuntimeSession.create!(
      {
        repository: repository,
        chat_session: chat_session,
        workspace_ref: @workspace,
        provider_key: "android_emulator",
        display_name: "Android emulator",
        state: "running",
        metadata: { "serial" => "emulator-5580" }
      }.merge(attrs)
    )
  end

  def toolchain_ready
    {
      "commands" => {
        "adb" => { "available" => true },
        "emulator" => { "available" => true },
        "avdmanager" => { "available" => true }
      },
      "emulator_runtime" => {
        "dev_kvm" => { "exists" => true, "readable" => true, "writable" => true },
        "acceleration_check" => { "ok" => true, "summary" => "accel ok" }
      }
    }
  end

  def command_seen?(*argv)
    runner.captures.any? { |call| call[:argv] == argv }
  end

  def png_with_dimensions(width:, height:)
    "\x89PNG\r\n\x1a\n".b +
      [ 13 ].pack("N") +
      "IHDR" +
      [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC") +
      "fakecrc"
  end

  describe ".detect and .capabilities" do
    it "detects Android workspaces and advertises visual/input operations" do
      FileUtils.mkdir_p(File.join(@workspace, "app/src/main"))
      File.write(File.join(@workspace, "app/src/main/AndroidManifest.xml"), "<manifest />")

      expect(described_class.detect(repository, workspace_path: @workspace)).to be true
      expect(described_class.capabilities(repository, {})).to include(
        stream: "screenshot",
        input: %w[touch pointer keyboard key text device_button],
        inspect: %w[uiautomator],
        artifacts: %w[screenshots logcat]
      )
    end
  end

  describe "#start_session" do
    it "creates an isolated AVD when needed, starts the emulator, and waits for boot readiness" do
      session = runtime_session(state: "starting", metadata: {})
      runner.enqueue(->(argv) { argv == %w[avdmanager list avd] }, stdout: "")
      runner.enqueue(->(argv) { argv.first(4) == %w[avdmanager create avd --force] })
      runner.enqueue(->(argv) { argv == [ "adb", "-s", "emulator-#{5554 + (session.id % 64) * 2}", "shell", "getprop", "sys.boot_completed" ] }, stdout: "1\n")

      metadata = provider.start_session(@workspace, runtime_session: session, system_image: "system-images;android-36;google_apis;x86_64")

      expect(metadata).to include(
        avd_name: "syrus-runtime-#{session.id}",
        avd_created: true,
        serial: "emulator-#{5554 + (session.id % 64) * 2}",
        emulator_pid: 12_345
      )
      expect(runner.captures.find { |call| call[:argv].first(4) == %w[avdmanager create avd --force] }[:stdin_data]).to eq("no\n")
      expect(runner.spawns.first[:argv]).to include("emulator", "-avd", "syrus-runtime-#{session.id}", "-no-window")
      expect(runner.spawns.first[:out]).to end_with("runtime-session-#{session.id}.log")
    end

    it "raises a clear missing SDK tool error before starting an emulator" do
      allow(Android::ToolchainDiagnostic).to receive(:call).and_return(
        toolchain_ready.deep_merge("commands" => { "adb" => { "available" => false } })
      )

      expect { provider.start_session(@workspace, runtime_session: runtime_session) }
        .to raise_error(described_class::RuntimeError, /missing Android SDK tools: adb/)
      expect(runner.spawns).to be_empty
    end

    it "cleans up the emulator and AVD after a boot timeout" do
      session = runtime_session(state: "starting", metadata: {})
      runner.enqueue(->(argv) { argv == %w[avdmanager list avd] }, stdout: "")
      runner.enqueue(->(argv) { argv.first(4) == %w[avdmanager create avd --force] })
      allow(provider).to receive(:sleep)

      expect do
        provider.start_session(@workspace, runtime_session: session, boot_timeout_seconds: 0)
      end.to raise_error(described_class::RuntimeError, /boot timeout/)

      expect(runner.killed_pids).to include(12_345)
      expect(command_seen?("avdmanager", "delete", "avd", "--name", "syrus-runtime-#{session.id}")).to be true
    end

    it "does not delete an existing AVD after a boot timeout" do
      session = runtime_session(state: "starting", metadata: {})
      runner.enqueue(->(argv) { argv == %w[avdmanager list avd] }, stdout: "Name: existing\n")
      allow(provider).to receive(:sleep)

      expect do
        provider.start_session(@workspace, runtime_session: session, avd_name: "existing", serial: "emulator-5580", boot_timeout_seconds: 0)
      end.to raise_error(described_class::RuntimeError, /boot timeout/)

      expect(runner.killed_pids).to include(12_345)
      expect(command_seen?("avdmanager", "delete", "avd", "--name", "existing")).to be false
    end
  end

  describe "#build_or_reload and #launch" do
    it "runs Gradle, installs the newest APK, and launches the package" do
      session = runtime_session
      File.write(File.join(@workspace, "gradlew"), "#!/bin/sh\n")
      FileUtils.chmod(0o755, File.join(@workspace, "gradlew"))
      apk = File.join(@workspace, "app/build/outputs/apk/debug/app-debug.apk")
      FileUtils.mkdir_p(File.dirname(apk))
      File.write(apk, "apk")
      FileUtils.mkdir_p(File.join(@workspace, "app/src/main"))
      File.write(File.join(@workspace, "app/src/main/AndroidManifest.xml"), '<manifest package="com.example.app" />')

      build = provider.build_or_reload(session.id, {})
      launch = provider.launch(session.id, {})

      expect(build).to include(gradle_task: "assembleDebug", installed_apk_path: apk)
      expect(command_seen?("./gradlew", "--no-daemon", "assembleDebug")).to be true
      expect(command_seen?("adb", "-s", "emulator-5580", "install", "-r", apk)).to be true
      expect(launch).to include(launched: true, package: "com.example.app")
      expect(command_seen?("adb", "-s", "emulator-5580", "shell", "monkey", "-p", "com.example.app", "-c", "android.intent.category.LAUNCHER", "1")).to be true
    end

    it "surfaces install failures with an actionable message" do
      session = runtime_session
      FileUtils.mkdir_p(File.join(@workspace, "build/outputs/apk/debug"))
      apk = File.join(@workspace, "build/outputs/apk/debug/app-debug.apk")
      File.write(apk, "apk")
      runner.enqueue(->(argv) { argv.include?("install") }, stderr: "INSTALL_FAILED_VERSION_DOWNGRADE", status: 1)

      expect { provider.build_or_reload(session.id, {}) }
        .to raise_error(described_class::RuntimeError, /INSTALL_FAILED_VERSION_DOWNGRADE/)
    end
  end

  describe "#snapshot and #inspect" do
    it "captures a PNG frame, files it as chat media, and stamps latest-frame metadata" do
      session = runtime_session
      png = png_with_dimensions(width: 1080, height: 2400)
      runner.enqueue(->(argv) { argv == %w[adb -s emulator-5580 exec-out screencap -p] }, stdout: png)

      payload = provider.snapshot(session.id)

      session.reload
      expect(payload).to include(kind: "android_screenshot", content_type: "image/png", bytes: png.bytesize, fallback: false)
      expect(session.latest_frame_url).to eq("/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{session.id}/frame")
      expect(session.metadata["latest_frame_document_id"]).to be_present
      expect(session.metadata).to include("frame_width" => 1080, "frame_height" => 2400)
      expect(chat_session.chat_attachments.reload.map(&:attachable_id)).to include(session.metadata["latest_frame_document_id"])
    end

    it "falls back to the latest captured frame when a refresh fails" do
      session = runtime_session(latest_frame_url: "/frame.png", latest_frame_at: 1.minute.ago, metadata: { "serial" => "emulator-5580", "latest_frame_document_id" => 99 })
      runner.enqueue(->(argv) { argv == %w[adb -s emulator-5580 exec-out screencap -p] }, stderr: "device offline", status: 1)

      payload = provider.snapshot(session.id)

      expect(payload).to include(fallback: true, latest_frame_url: "/frame.png", document_id: 99)
      expect(payload[:warning]).to include("device offline")
    end

    it "returns the uiautomator hierarchy XML" do
      session = runtime_session
      runner.enqueue(->(argv) { argv == %w[adb -s emulator-5580 exec-out uiautomator dump /dev/tty] }, stdout: "UI hierchary dumped to: /dev/tty\n<?xml version='1.0'?><hierarchy />")

      payload = provider.inspect(session.id)

      expect(payload).to include(kind: "android_uiautomator")
      expect(payload[:xml]).to start_with("<?xml")
    end
  end

  describe "#input and #logs" do
    it "requires an active lease before delivering touch input" do
      session = runtime_session

      expect(provider.input(session.id, { type: "touch", action: "tap", x: 5, y: 7 }))
        .to include(error: "lease_required")
      expect(runner.captures).to be_empty
    end

    it "delivers touch, text, and device button events through adb while leased" do
      session = runtime_session
      RuntimeControlLease.acquire!(runtime_session: session, owner: "agent", mode: "input", reason: "drive app")

      expect(provider.input(session.id, { type: "touch", action: "tap", x: 5, y: 7 })).to include(delivered: true)
      expect(provider.input(session.id, { type: "text", text: "hello world" })).to include(delivered: true)
      expect(provider.input(session.id, { type: "device_button", button: "back" })).to include(delivered: true)

      expect(command_seen?("adb", "-s", "emulator-5580", "shell", "input", "tap", "5", "7")).to be true
      expect(command_seen?("adb", "-s", "emulator-5580", "shell", "input", "text", "hello%sworld")).to be true
      expect(command_seen?("adb", "-s", "emulator-5580", "shell", "input", "keyevent", "KEYCODE_BACK")).to be true
    end

    it "scales Runtime panel normalized pointer coordinates to screenshot pixels" do
      session = runtime_session(metadata: { "serial" => "emulator-5580", "frame_width" => 1080, "frame_height" => 2400 })
      RuntimeControlLease.acquire!(runtime_session: session, owner: "user", owner_ref: "operator:#{user.id}", mode: "input", reason: "manual tap")

      result = provider.input(
        session.id,
        {
          type: "pointer",
          action: "click",
          x: 54,
          y: 120,
          normalized_x: 0.5,
          normalized_y: 0.25,
          source_width: 108,
          source_height: 240,
          "_runtime_control_owner" => "user"
        }
      )

      expect(result).to include(delivered: true)
      expect(command_seen?("adb", "-s", "emulator-5580", "shell", "input", "tap", "540", "600")).to be true
    end

    it "pages logcat output by cursor" do
      session = runtime_session
      runner.enqueue(->(argv) { argv == %w[adb -s emulator-5580 logcat -d -v time] }, stdout: "one\ntwo\nthree\n")

      expect(provider.logs(session.id, 1, limit: 1)).to eq(entries: [ "two" ], cursor: 2)
    end
  end

  describe "#stop_session" do
    it "kills the emulator and remembered process" do
      session = runtime_session(metadata: { "serial" => "emulator-5580", "emulator_pid" => 12_345 })

      expect(provider.stop_session(session.id)).to be true

      expect(command_seen?("adb", "-s", "emulator-5580", "emu", "kill")).to be true
      expect(runner.killed_pids).to include(12_345)
    end
  end

  describe "runtime_start integration" do
    before do
      enable_coding_mode!
      Syrus::PluginRegistry.register(:runtime_session_provider, Android::EmulatorRuntimeSessionProvider)
      FileUtils.mkdir_p(File.join(@workspace, "app/src/main"))
      File.write(File.join(@workspace, "app/src/main/AndroidManifest.xml"), "<manifest />")
      allow(ChatWorkspace).to receive(:repo_path_for).with(chat_session, repository).and_return(Pathname.new(@workspace))
    end

    def tool_payload(response)
      JSON.parse(response.content.first[:text], symbolize_names: true)
    end

    it "starts and persists an Android Runtime Session payload through the generic MCP tool" do
      runner.enqueue(->(argv) { argv == %w[avdmanager list avd] }, stdout: "Name: existing\n")
      runner.enqueue(->(argv) { argv.include?("getprop") }, stdout: "1\n")

      response = Mcp::Tools::RuntimeStartTool.call(
        provider: "android_emulator",
        options: { avd_name: "existing", serial: "emulator-5580" },
        server_context: { chat_session: chat_session }
      )

      payload = tool_payload(response)
      session = RuntimeSession.find(payload.fetch(:id))

      expect(response).not_to be_error
      expect(payload).to include(provider_key: "android_emulator", state: "running")
      expect(payload.dig(:capabilities, :input)).to include("touch", "text")
      expect(session.metadata).to include("avd_name" => "existing", "serial" => "emulator-5580", "emulator_pid" => 12_345)
    end

    it "returns a failed Runtime Session with a clear failure when startup cannot create the AVD" do
      runner.enqueue(->(argv) { argv == %w[avdmanager list avd] }, stdout: "")
      runner.enqueue(->(argv) { argv.first(4) == %w[avdmanager create avd --force] }, stderr: "Package path is not valid", status: 1)

      response = Mcp::Tools::RuntimeStartTool.call(
        provider: "android_emulator",
        options: { avd_name: "missing-image", serial: "emulator-5580" },
        server_context: { chat_session: chat_session }
      )

      failed_session = chat_session.runtime_sessions.order(:created_at).last
      expect(response).to be_error
      expect(response.content.first[:text]).to include("failed to create Android AVD")
      expect(failed_session).to have_attributes(provider_key: "android_emulator", state: "failed")
      expect(failed_session.last_error).to include("Package path is not valid")
    end
  end
end
