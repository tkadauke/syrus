require "open3"
require "timeout"

module Android
  class ToolchainDiagnostic
    DEFAULT_SDK_ROOT = "/opt/android-sdk"
    DEFAULT_PLATFORM = "android-36"
    DEFAULT_BUILD_TOOLS = "36.0.0"
    COMMAND_TIMEOUT_SECONDS = 10

    CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def success? = status.to_i.zero?
    end

    COMMANDS = {
      "sdkmanager" => [ "--version" ],
      "avdmanager" => [ "--help" ],
      "adb" => [ "version" ],
      "emulator" => [ "-version" ],
      "java" => [ "-version" ],
      "javac" => [ "-version" ],
      "gradle" => [ "--version" ]
    }.freeze

    def self.call(env: ENV, platform: DEFAULT_PLATFORM, build_tools: DEFAULT_BUILD_TOOLS, runner: nil)
      new(env: env, platform: platform, build_tools: build_tools, runner: runner).call
    end

    def initialize(env:, platform:, build_tools:, runner:)
      @env = env.to_h.transform_keys(&:to_s)
      @platform = platform
      @build_tools = build_tools
      @runner = runner || method(:run_command)
    end

    def call
      {
        "sdk" => sdk_diagnostic,
        "packages" => package_diagnostics,
        "commands" => command_diagnostics,
        "emulator_runtime" => emulator_runtime_diagnostic,
        "jvm" => jvm_diagnostic
      }
    end

    private

    attr_reader :env, :platform, :build_tools, :runner

    def sdk_diagnostic
      {
        "android_home" => env["ANDROID_HOME"],
        "android_sdk_root" => env["ANDROID_SDK_ROOT"],
        "resolved_sdk_root" => sdk_root.to_s,
        "exists" => sdk_root.directory?,
        "licenses_accepted" => licenses_accepted?,
        "android_user_home" => env["ANDROID_USER_HOME"],
        "android_avd_home" => env["ANDROID_AVD_HOME"]
      }
    end

    def package_diagnostics
      {
        "cmdline_tools" => directory_package("cmdline-tools/latest"),
        "platform_tools" => directory_package("platform-tools"),
        "emulator" => directory_package("emulator"),
        "platform" => directory_package("platforms/#{platform}"),
        "build_tools" => directory_package("build-tools/#{build_tools}")
      }
    end

    def command_diagnostics
      COMMANDS.transform_values do |args|
        probe_command(args)
      end
    end

    def emulator_runtime_diagnostic
      accel = command_available?("emulator") ? probe_command([ "-accel-check" ], command: "emulator") : unavailable("emulator not on PATH")

      {
        "dev_kvm" => {
          "exists" => File.exist?("/dev/kvm"),
          "readable" => File.readable?("/dev/kvm"),
          "writable" => File.writable?("/dev/kvm")
        },
        "cpu_virtualization_flag" => cpu_virtualization_flag?,
        "acceleration_check" => accel
      }
    end

    def jvm_diagnostic
      {
        "java" => probe_command([ "-version" ], command: "java"),
        "javac" => probe_command([ "-version" ], command: "javac"),
        "gradle" => probe_command([ "--version" ], command: "gradle"),
        "mise_version_file" => Java::PrepareDetector.mise_version_file
      }
    end

    def directory_package(relative_path)
      path = sdk_root.join(relative_path)

      {
        "path" => path.to_s,
        "ready" => path.directory?
      }
    end

    def probe_command(args, command: nil)
      name = command || COMMANDS.key(args)
      path = executable_path(name)
      return unavailable("not on PATH") unless path

      result = runner.call([ path, *args ], env)
      {
        "available" => true,
        "path" => path,
        "ok" => result.success?,
        "exit_status" => result.status,
        "summary" => first_output_line(result),
        "stderr" => truncate(result.stderr)
      }.compact
    rescue Timeout::Error
      {
        "available" => true,
        "path" => path,
        "ok" => false,
        "exit_status" => 124,
        "summary" => "timed out after #{COMMAND_TIMEOUT_SECONDS}s"
      }
    rescue SystemCallError => e
      {
        "available" => true,
        "path" => path,
        "ok" => false,
        "summary" => "#{e.class}: #{e.message}"
      }
    end

    def unavailable(reason)
      {
        "available" => false,
        "ok" => false,
        "summary" => reason
      }
    end

    def command_available?(name)
      executable_path(name).present?
    end

    def executable_path(name)
      env.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |dir|
        path = File.join(dir, name)
        path if File.file?(path) && File.executable?(path)
      end.first
    end

    def run_command(argv, command_env)
      stdout, stderr, status = Timeout.timeout(COMMAND_TIMEOUT_SECONDS) do
        Open3.capture3(command_env, *argv)
      end

      CommandResult.new(stdout: stdout, stderr: stderr, status: status.exitstatus)
    end

    def first_output_line(result)
      output = [ result.stdout, result.stderr ].join("\n")
      line = output.lines.map(&:strip).find(&:present?)
      truncate(line)
    end

    def truncate(value, length = 500)
      return nil if value.blank?

      value.to_s.length > length ? "#{value.to_s[0, length]}..." : value.to_s
    end

    def licenses_accepted?
      licenses_path = sdk_root.join("licenses")
      licenses_path.directory? && Dir.children(licenses_path).any?
    end

    def cpu_virtualization_flag?
      cpuinfo = File.read("/proc/cpuinfo")
      cpuinfo.match?(/\b(?:vmx|svm)\b/)
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def sdk_root
      @sdk_root ||= Pathname.new(env["ANDROID_SDK_ROOT"].presence || env["ANDROID_HOME"].presence || DEFAULT_SDK_ROOT)
    end
  end
end
