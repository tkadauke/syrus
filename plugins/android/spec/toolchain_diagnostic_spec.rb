require "rails_helper"
require "shellwords"
require "tmpdir"

RSpec.describe Android::ToolchainDiagnostic do
  around do |ex|
    Dir.mktmpdir("syrus-android-diagnostic") do |dir|
      @dir = Pathname.new(dir)
      @bin = @dir.join("bin")
      @sdk = @dir.join("sdk")
      FileUtils.mkdir_p(@bin)
      ex.run
    end
  end

  def executable(name, output:, stderr: "", exit_status: 0)
    path = @bin.join(name)
    path.write(<<~SH)
      #!/bin/sh
      printf '%s\\n' #{Shellwords.escape(output)}
      printf '%s\\n' #{Shellwords.escape(stderr)} >&2
      exit #{exit_status}
    SH
    FileUtils.chmod(0755, path)
  end

  def env
    {
      "PATH" => @bin.to_s,
      "ANDROID_HOME" => @sdk.to_s,
      "ANDROID_SDK_ROOT" => @sdk.to_s,
      "ANDROID_USER_HOME" => @dir.join(".syrus/android").to_s,
      "ANDROID_AVD_HOME" => @dir.join(".syrus/android/avd").to_s
    }
  end

  it "reports installed SDK packages, accepted licenses, Android commands, and JVM facts" do
    %w[
      cmdline-tools/latest
      platform-tools
      emulator
      platforms/android-36
      build-tools/36.0.0
      licenses
    ].each { |path| FileUtils.mkdir_p(@sdk.join(path)) }
    @sdk.join("licenses/android-sdk-license").write("accepted")

    executable("sdkmanager", output: "16.0")
    executable("avdmanager", output: "Usage: avdmanager")
    executable("adb", output: "Android Debug Bridge version 1.0.41")
    executable("emulator", output: "Android emulator version 36.1")
    executable("java", output: "", stderr: 'openjdk version "21"')
    executable("javac", output: "javac 21")
    executable("gradle", output: "Gradle 9.0")

    diagnostic = described_class.call(env: env)

    expect(diagnostic.dig("sdk", "exists")).to be true
    expect(diagnostic.dig("sdk", "licenses_accepted")).to be true
    expect(diagnostic.dig("packages", "platform", "ready")).to be true
    expect(diagnostic.dig("packages", "build_tools", "ready")).to be true
    expect(diagnostic.dig("commands", "adb", "summary")).to include("Android Debug Bridge")
    expect(diagnostic.dig("commands", "emulator", "available")).to be true
    expect(diagnostic.dig("jvm", "java", "summary")).to include("openjdk version")
    expect(diagnostic.dig("jvm", "mise_version_file")).to eq(".java-version")
    expect(diagnostic.dig("emulator_runtime", "dev_kvm")).to include("exists", "readable", "writable")
    expect(diagnostic.dig("emulator_runtime", "acceleration_check", "available")).to be true
  end

  it "reports missing SDK packages and absent commands without raising" do
    FileUtils.mkdir_p(@sdk)
    executable("java", output: "", stderr: 'openjdk version "21"')

    diagnostic = described_class.call(env: env)

    expect(diagnostic.dig("sdk", "exists")).to be true
    expect(diagnostic.dig("sdk", "licenses_accepted")).to be false
    expect(diagnostic.dig("packages", "platform_tools", "ready")).to be false
    expect(diagnostic.dig("commands", "adb")).to include(
      "available" => false,
      "ok" => false,
      "summary" => "not on PATH"
    )
    expect(diagnostic.dig("jvm", "java", "summary")).to include("openjdk version")
  end

  it "returns a non-fatal diagnostic and finalizes a timed-out probe" do
    stub_const("Android::ToolchainDiagnostic::COMMAND_TIMEOUT_SECONDS", 0.05)
    executable("adb", output: "", exit_status: 0)
    @bin.join("adb").write("#!/bin/sh\n/bin/sleep 30\n")
    FileUtils.chmod(0o755, @bin.join("adb"))

    diagnostic = described_class.call(env: env)

    expect(diagnostic.dig("commands", "adb")).to include(
      "available" => true,
      "ok" => false,
      "exit_status" => 124,
      "summary" => "timed out after 0.05s"
    )
    expect(SpawnedProcess.where(kind: "runtime_probe").order(:id).last).to have_attributes(outcome: "timed_out")
  end
end
