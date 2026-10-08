require "open3"
require "securerandom"
require "syrus/plugin/runtime_session_provider"
require "timeout"

module Android
  class EmulatorRuntimeSessionProvider
    include Syrus::Plugin::RuntimeSessionProvider

    BOOT_TIMEOUT_SECONDS = 120
    BOOT_POLL_INTERVAL_SECONDS = 2
    DEFAULT_GRADLE_TASK = "assembleDebug"
    DEFAULT_APK_GLOB = "{app/,}build/outputs/apk/**/*.apk"
    DEFAULT_LOG_LIMIT = 200
    FRAME_STALE_AFTER = 10.seconds

    CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def success? = status.to_i.zero?
      def combined_output = [ stdout, stderr ].compact.join("\n").strip
    end

    ProcessHandle = Struct.new(:pid, keyword_init: true)

    class RuntimeError < StandardError; end

    class CommandRunner
      def capture(argv, env:, chdir: nil, timeout: 60, stdin_data: nil)
        stdout, stderr, status = Timeout.timeout(timeout) do
          Open3.capture3(env, *argv, chdir: chdir, stdin_data: stdin_data)
        end
        CommandResult.new(stdout: stdout, stderr: stderr, status: status.exitstatus)
      rescue Timeout::Error
        CommandResult.new(stdout: "", stderr: "timed out after #{timeout}s", status: 124)
      end

      def spawn(argv, env:, chdir: nil, out: File::NULL, err: File::NULL)
        pid = Process.spawn(env, *argv, chdir: chdir, out: out, err: err)
        Process.detach(pid)
        ProcessHandle.new(pid: pid)
      end

      def kill(pid)
        Process.kill("TERM", pid.to_i)
      rescue Errno::ESRCH, TypeError
        nil
      end
    end

    class << self
      attr_writer :command_runner

      def provider_key = "android_emulator"
      def display_name = "Android emulator"

      def detect(_repository, config)
        workspace_path = config[:workspace_path] || config["workspace_path"]
        workspace_path.present? && Android::PrepareDetector.detect?(workspace_path)
      end

      def capabilities(_repository, _config)
        {
          stream: "screenshot",
          input: %w[touch pointer keyboard key text device_button],
          inspect: %w[uiautomator],
          build: %w[gradle_install reload],
          artifacts: %w[screenshots logcat]
        }
      end

      def command_runner
        @command_runner ||= CommandRunner.new
      end

      def reset_command_runner!
        @command_runner = nil
      end
    end

    def start_session(workspace_ref, config)
      serial = avd_name = handle = session_env = nil
      config = config.to_h.symbolize_keys
      runtime_session = config.fetch(:runtime_session)
      session_env = env_for(workspace_ref, config)
      validate_toolchain!(session_env)

      serial = config[:serial].presence || emulator_serial_for(runtime_session)
      avd_name = config[:avd_name].presence || "syrus-runtime-#{runtime_session.id}"
      log_path = runtime_log_path(workspace_ref, runtime_session)

      ensure_avd!(avd_name, config, env: session_env, chdir: workspace_ref)
      handle = start_emulator!(avd_name, serial, config, env: session_env, chdir: workspace_ref, log_path: log_path)
      wait_for_boot!(serial, env: session_env, chdir: workspace_ref, timeout: Integer(config[:boot_timeout_seconds] || BOOT_TIMEOUT_SECONDS))

      {
        avd_name: avd_name,
        serial: serial,
        emulator_pid: handle.pid,
        emulator_log_path: log_path,
        android_env: session_env.slice("ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_USER_HOME")
      }.compact
    rescue StandardError => e
      cleanup_after_start_failure(serial: serial, avd_name: avd_name, pid: handle&.pid, env: session_env, chdir: workspace_ref, delete_avd: config[:delete_avd_on_failure] != false)
      raise e
    end

    def build_or_reload(session_id, options)
      runtime_session = runtime_session_for(session_id)
      options = options.to_h.symbolize_keys
      gradle_task = options[:gradle_task].presence || runtime_session.metadata["gradle_task"].presence || DEFAULT_GRADLE_TASK
      run_gradle!(runtime_session, gradle_task)

      apk_path = options[:apk_path].presence || newest_apk(runtime_session.workspace_ref)
      raise RuntimeError, "install failed: no APK found after Gradle task #{gradle_task.inspect}" if apk_path.blank?

      install = adb!(runtime_session, "install", "-r", apk_path, timeout: Integer(options[:install_timeout_seconds] || 120))

      {
        gradle_task: gradle_task,
        installed_apk_path: apk_path,
        install_output: install.combined_output
      }
    end

    def launch(session_id, options)
      runtime_session = runtime_session_for(session_id)
      options = options.to_h.symbolize_keys
      package_name = options[:package].presence || runtime_session.metadata["package"].presence || inferred_package(runtime_session.workspace_ref)
      raise RuntimeError, "app launch failed: package name is required (pass package: or declare it in AndroidManifest.xml)" if package_name.blank?

      activity = options[:activity].presence || runtime_session.metadata["activity"].presence
      result = if activity.present?
        adb!(runtime_session, "shell", "am", "start", "-n", "#{package_name}/#{activity}")
      else
        adb!(runtime_session, "shell", "monkey", "-p", package_name, "-c", "android.intent.category.LAUNCHER", "1")
      end

      { launched: true, package: package_name, activity: activity, output: result.combined_output }.compact
    end

    def snapshot(session_id, options = {})
      runtime_session = runtime_session_for(session_id)
      options = options.to_h.symbolize_keys

      if options[:fallback] && runtime_session.latest_frame_at.present? && runtime_session.latest_frame_at > FRAME_STALE_AFTER.ago
        return latest_frame_payload(runtime_session, fallback: true)
      end

      result = adb!(runtime_session, "exec-out", "screencap", "-p", timeout: Integer(options[:timeout_seconds] || 30))
      png = result.stdout.to_s.b
      raise RuntimeError, "frame refresh failed: adb screencap returned no PNG bytes" if png.blank?

      document = persist_frame(runtime_session, png)
      latest_frame_payload(runtime_session.reload, document: document, bytes: png.bytesize, fallback: false)
    rescue StandardError => e
      return latest_frame_payload(runtime_session.reload, fallback: true, warning: e.message) if runtime_session.latest_frame_url.present?

      raise RuntimeError, "frame refresh failed: #{e.message}"
    end

    def inspect(session_id = nil, _options = nil)
      raise NotImplementedError, "#{self.class}#inspect requires a session_id" if session_id.nil?

      runtime_session = runtime_session_for(session_id)
      result = adb!(runtime_session, "exec-out", "uiautomator", "dump", "/dev/tty", timeout: 30)
      xml = result.stdout.to_s.sub(/\A.*?<\?xml/m, "<?xml").strip

      { kind: "android_uiautomator", xml: xml, bytes: xml.bytesize }
    end

    def input(session_id, event)
      runtime_session = runtime_session_for(session_id)
      event = event.to_h.stringify_keys
      owner = event.delete("_runtime_control_owner").presence || "agent"
      lease = input_lease_for(runtime_session, owner)

      unless lease
        RuntimeControlLease.audit_input_rejected!(runtime_session: runtime_session, event: event)
        return { error: "lease_required", message: "the #{owner} must hold an active input lease before sending input events" }
      end

      argv = InputEvent.for(event).adb_args
      adb!(runtime_session, *argv)
      lease.record_input!(event)

      { delivered: true, event: event }
    rescue ArgumentError => e
      { error: "unsupported_input", message: e.message }
    rescue RuntimeError => e
      { error: "input_failed", message: e.message }
    end

    def logs(session_id, cursor, options)
      runtime_session = runtime_session_for(session_id)
      limit = Integer(options.to_h.symbolize_keys[:limit] || DEFAULT_LOG_LIMIT)
      result = adb!(runtime_session, "logcat", "-d", "-v", "time", timeout: 30)
      lines = result.stdout.to_s.lines.map(&:chomp)
      start_index = cursor.to_i.clamp(0, lines.size)
      entries = lines[start_index, limit] || []

      { entries: entries, cursor: start_index + entries.size }
    end

    def stop_session(session_id)
      runtime_session = runtime_session_for(session_id)
      env = env_for(runtime_session.workspace_ref, runtime_session.metadata)
      adb(runtime_session, "emu", "kill", timeout: 10)
      self.class.command_runner.kill(runtime_session.metadata["emulator_pid"]) if runtime_session.metadata["emulator_pid"].present?
      delete_avd(runtime_session.metadata["avd_name"], env: env, chdir: runtime_session.workspace_ref) if runtime_session.metadata["delete_avd_on_stop"]
      true
    end

    private

    def validate_toolchain!(env)
      diagnostic = Android::ToolchainDiagnostic.call(env: env)
      missing = %w[adb emulator avdmanager].filter_map do |command|
        command unless diagnostic.dig("commands", command, "available")
      end
      raise RuntimeError, "missing Android SDK tools: #{missing.join(', ')}" if missing.any?

      runtime = diagnostic.fetch("emulator_runtime", {})
      kvm = runtime.fetch("dev_kvm", {})
      unless kvm["exists"] && kvm["readable"] && kvm["writable"]
        raise RuntimeError, "no emulator accelerator support: /dev/kvm must exist and be readable/writable by the worker"
      end

      accel = runtime.dig("acceleration_check", "ok")
      raise RuntimeError, "no emulator accelerator support: #{runtime.dig('acceleration_check', 'summary')}" if accel == false
    end

    def ensure_avd!(avd_name, config, env:, chdir:)
      existing = capture!(%w[avdmanager list avd], env: env, chdir: chdir)
      return if existing.stdout.to_s.match?(/Name:\s+#{Regexp.escape(avd_name)}\b/)

      package = config[:system_image].presence || "system-images;android-36;google_apis;x86_64"
      device = config[:device].presence || "pixel_6"
      capture!(
        [ "avdmanager", "create", "avd", "--force", "--name", avd_name, "--package", package, "--device", device ],
        env: env,
        chdir: chdir,
        timeout: Integer(config[:avd_timeout_seconds] || 120),
        stdin_data: "no\n"
      )
    rescue RuntimeError => e
      raise RuntimeError, "failed to create Android AVD #{avd_name.inspect}: #{e.message}"
    end

    def start_emulator!(avd_name, serial, config, env:, chdir:, log_path:)
      port = serial.to_s[/\Aemulator-(\d+)\z/, 1] || emulator_port_for_avd
      argv = [
        "emulator", "-avd", avd_name,
        "-port", port.to_s,
        "-no-window",
        "-no-audio",
        "-no-boot-anim",
        "-gpu", config[:gpu].presence || "swiftshader_indirect"
      ]
      argv << "-no-snapshot-load" if config[:no_snapshot_load] != false
      FileUtils.mkdir_p(File.dirname(log_path))
      self.class.command_runner.spawn(argv, env: env, chdir: chdir, out: log_path, err: log_path)
    rescue SystemCallError => e
      raise RuntimeError, "failed to start Android emulator: #{e.message}"
    end

    def wait_for_boot!(serial, env:, chdir:, timeout:)
      deadline = Time.current + timeout.seconds

      loop do
        booted = capture([ "adb", "-s", serial, "shell", "getprop", "sys.boot_completed" ], env: env, chdir: chdir, timeout: 10)
        return true if booted.success? && booted.stdout.to_s.strip == "1"
        break if Time.current >= deadline

        sleep BOOT_POLL_INTERVAL_SECONDS
      end

      raise RuntimeError, "boot timeout: Android emulator #{serial} did not become ready within #{timeout}s"
    end

    def cleanup_after_start_failure(serial:, avd_name:, pid:, env:, chdir:, delete_avd:)
      self.class.command_runner.kill(pid) if pid
      capture([ "adb", "-s", serial, "emu", "kill" ], env: env, chdir: chdir, timeout: 10) if serial.present?
      delete_avd(avd_name, env: env, chdir: chdir) if delete_avd && avd_name.present?
    rescue StandardError
      nil
    end

    def run_gradle!(runtime_session, task)
      command = File.executable?(File.join(runtime_session.workspace_ref, "gradlew")) ? "./gradlew" : "gradle"
      result = capture!(
        [ command, "--no-daemon", task ],
        env: env_for(runtime_session.workspace_ref, runtime_session.metadata),
        chdir: runtime_session.workspace_ref,
        timeout: 600
      )
      result
    rescue RuntimeError => e
      raise RuntimeError, "build/reload failed: #{e.message}"
    end

    def newest_apk(workspace_ref)
      Dir.glob(File.join(workspace_ref, DEFAULT_APK_GLOB)).max_by { |path| File.mtime(path) }
    end

    def inferred_package(workspace_ref)
      manifest = Dir.glob(File.join(workspace_ref, "**/src/main/AndroidManifest.xml")).first
      return nil unless manifest

      File.read(manifest)[/\bpackage\s*=\s*["']([^"']+)["']/, 1]
    rescue Errno::ENOENT
      nil
    end

    def persist_frame(runtime_session, png)
      chat_session = runtime_session.chat_session
      return nil unless chat_session

      document = ChatMediaLibrary.materialize_captured_image!(
        chat_session,
        bytes: png,
        content_type: "image/png",
        title: "Android emulator frame"
      )
      runtime_session.update!(
        latest_frame_url: "/api/v1/app/chats/#{chat_session.id}/runtime_sessions/#{runtime_session.id}/frame",
        latest_frame_at: Time.current,
        metadata: runtime_session.metadata.merge("latest_frame_document_id" => document.id)
      )
      document
    end

    def latest_frame_payload(runtime_session, document: nil, bytes: nil, fallback: nil, warning: nil)
      {
        kind: "android_screenshot",
        content_type: "image/png",
        bytes: bytes,
        document_id: document&.id || runtime_session.metadata["latest_frame_document_id"],
        latest_frame_url: runtime_session.latest_frame_url,
        latest_frame_at: runtime_session.latest_frame_at&.iso8601,
        fallback: fallback,
        warning: warning
      }.compact
    end

    def input_lease_for(runtime_session, owner)
      if owner == "user"
        runtime_session.runtime_control_leases.active.held_by("user").for_mode("input").first
      else
        runtime_session.active_agent_input_lease
      end
    end

    def adb!(runtime_session, *args, timeout: 60)
      result = adb(runtime_session, *args, timeout: timeout)
      return result if result.success?

      raise RuntimeError, result.combined_output.presence || "adb #{args.join(' ')} failed with exit #{result.status}"
    end

    def adb(runtime_session, *args, timeout: 60)
      capture(
        [ "adb", "-s", runtime_session.metadata.fetch("serial"), *args ],
        env: env_for(runtime_session.workspace_ref, runtime_session.metadata),
        chdir: runtime_session.workspace_ref,
        timeout: timeout
      )
    end

    def capture!(argv, env:, chdir:, timeout: 60, stdin_data: nil)
      result = capture(argv, env: env, chdir: chdir, timeout: timeout, stdin_data: stdin_data)
      return result if result.success?

      raise RuntimeError, result.combined_output.presence || "#{argv.join(' ')} failed with exit #{result.status}"
    end

    def capture(argv, env:, chdir:, timeout: 60, stdin_data: nil)
      self.class.command_runner.capture(argv, env: env, chdir: chdir, timeout: timeout, stdin_data: stdin_data)
    end

    def delete_avd(avd_name, env:, chdir:)
      capture([ "avdmanager", "delete", "avd", "--name", avd_name ], env: env, chdir: chdir, timeout: 60)
    end

    def env_for(workspace_ref, config)
      config = config.to_h.stringify_keys
      workspace_env = Android::StepEnvironment.extra_env(scope: nil, workspace_path: workspace_ref)
      ENV.to_h.merge(config.fetch("env", {})).merge(workspace_env)
    end

    def runtime_session_for(session_id)
      return session_id if session_id.is_a?(RuntimeSession)

      RuntimeSession.find(session_id)
    end

    def emulator_serial_for(runtime_session)
      "emulator-#{5554 + (runtime_session.id.to_i % 64) * 2}"
    end

    def emulator_port_for_avd
      5554 + SecureRandom.random_number(64) * 2
    end

    def runtime_log_path(workspace_ref, runtime_session)
      File.join(workspace_ref, ".syrus", "android", "runtime-session-#{runtime_session.id}.log")
    end

    class InputEvent
      def self.for(event)
        event_type = event.fetch("type", "").to_s
        event_class = registry.fetch(event_type) { raise ArgumentError, "unsupported Android input event #{event.inspect}" }
        event_class.new(event)
      end

      def self.registry
        {
          "pointer" => Touch,
          "touch" => Touch,
          "keyboard" => Key,
          "key" => Key,
          "device_button" => Key,
          "text" => Text
        }
      end

      def initialize(event)
        @event = event
      end

      private

      attr_reader :event

      def integer!(value, name)
        Integer(value)
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{name} must be an integer"
      end
    end

    class Touch < InputEvent
      def adb_args
        action = event["action"].to_s
        return tap_args if action.blank? || action == "tap" || action == "click"
        return swipe_args if action == "swipe" || action == "drag"

        raise ArgumentError, "unsupported Android touch action #{action.inspect}"
      end

      private

      def tap_args
        [ "shell", "input", "tap", integer!(event["x"], "x").to_s, integer!(event["y"], "y").to_s ]
      end

      def swipe_args
        [
          "shell", "input", "swipe",
          integer!(event["x"], "x").to_s,
          integer!(event["y"], "y").to_s,
          integer!(event["to_x"], "to_x").to_s,
          integer!(event["to_y"], "to_y").to_s,
          Integer(event["duration_ms"].presence || 300).to_s
        ]
      end
    end

    class Key < InputEvent
      KEYCODES = {
        "BACK" => "KEYCODE_BACK",
        "HOME" => "KEYCODE_HOME",
        "MENU" => "KEYCODE_MENU",
        "ENTER" => "KEYCODE_ENTER",
        "TAB" => "KEYCODE_TAB",
        "ESCAPE" => "KEYCODE_ESCAPE",
        "POWER" => "KEYCODE_POWER",
        "VOLUME_UP" => "KEYCODE_VOLUME_UP",
        "VOLUME_DOWN" => "KEYCODE_VOLUME_DOWN"
      }.freeze

      def adb_args
        [ "shell", "input", "keyevent", keycode ]
      end

      private

      def keycode
        value = event["key"].presence || event["button"].presence || event["action"]
        normalized = value.to_s.strip.upcase
        return normalized if normalized.start_with?("KEYCODE_")
        return normalized if normalized.match?(/\A\d+\z/)

        KEYCODES.fetch(normalized) { "KEYCODE_#{normalized}" }
      end
    end

    class Text < InputEvent
      def adb_args
        text = event["text"].to_s
        raise ArgumentError, "text is required" if text.blank?

        [ "shell", "input", "text", text.gsub(/\s+/, "%s") ]
      end
    end
  end
end
