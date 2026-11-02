require "rails_helper"

RSpec.describe WorkerCapabilities do
  def probe_result(success:, output: "", status: nil)
    described_class::CommandResult.new(
      success: success,
      output: output,
      status: status || (success ? "available" : "failed")
    )
  end

  def with_capability_env(value)
    previous = ENV[described_class::ENV_KEY]
    value.nil? ? ENV.delete(described_class::ENV_KEY) : ENV[described_class::ENV_KEY] = value
    yield
  ensure
    previous.nil? ? ENV.delete(described_class::ENV_KEY) : ENV[described_class::ENV_KEY] = previous
  end

  describe "probe detection" do
    # Detection runs on every instance heartbeat (InstanceVersionSupervisor,
    # WorkerHostHealthSampler) and spawns a subprocess per probe, so repeating
    # it on each call would be several processes for an answer that cannot
    # change without a restart.
    it "probes once per process rather than on every call" do
      allow(described_class).to receive(:command_result).and_return(probe_result(success: true))

      3.times { described_class.current }

      expect(described_class).to have_received(:command_result)
        .at_most(described_class::TOOL_PROBES.size + described_class.send(:plugin_tool_probes).size + 4).times
    end

    it "probes tool versions once per process rather than for every environment fingerprint" do
      allow(described_class).to receive(:command_result).and_return(probe_result(success: false))
      capture = double(success?: true, stdout: "version 1\n", stderr: "")
      allow(described_class).to receive(:capability_probe).and_return(capture)

      3.times { described_class.environment_fingerprint_metadata }

      expect(described_class).to have_received(:capability_probe)
        .exactly(described_class::VERSION_PROBES.size).times
    end
  end

  describe ".parse" do
    it "normalizes comma and space separated execution capabilities" do
      expect(described_class.parse("os:macos,arch:arm64 toolchain:xcode,runtime:ios_simulator,feature:docker")).to eq(
        "os" => [ "macos" ],
        "arch" => [ "arm64" ],
        "toolchain" => [ "xcode" ],
        "runtime" => [ "ios_simulator" ]
      )
    end

    it "drops blank dimensions, unknown dimensions, and unsupported OS values" do
      expect(described_class.parse("os:linux,unknown:value,os:windows,bad")).to eq("os" => [ "linux" ])
    end
  end

  describe ".normalize" do
    it "accepts a JSON-encoded string from a double-encoded json column" do
      expect(described_class.normalize('{"os":["linux"]}')).to eq("os" => [ "linux" ])
    end

    it "accepts an env-style string with supported capability dimensions" do
      expect(described_class.normalize("os:linux,arch:arm64")).to eq(
        "os" => [ "linux" ],
        "arch" => [ "arm64" ]
      )
    end

    it "accepts execution capability objects" do
      capabilities = TargetGraph::ExecutionCapabilities.new(os: [ "macos" ], arch: "arm64", toolchain: "xcode")

      expect(described_class.normalize(capabilities)).to eq(
        "os" => [ "macos" ],
        "arch" => [ "arm64" ],
        "toolchain" => [ "xcode" ]
      )
    end

    it "rejects non-hash capability values with a controlled error" do
      expect {
        described_class.normalize(Object.new)
      }.to raise_error(ArgumentError, "worker capabilities must be a Hash, String, or TargetGraph::ExecutionCapabilities")
    end
  end

  describe ".current" do
    it "lets configured capabilities override detected defaults" do
      allow(described_class).to receive(:command_result).and_return(probe_result(success: false))

      with_capability_env("os:macos,arch:arm64,toolchain:xcode,runtime:ios_simulator") do
        payload = described_class.current

        expect(payload.fetch(:capabilities)).to eq(
          "os" => [ "macos" ],
          "arch" => [ "arm64" ],
          "toolchain" => [ "xcode" ],
          "runtime" => [ "ios_simulator" ]
        )
        expect(payload.fetch(:diagnostics)).to include(
          "configured" => true,
          "env_key" => described_class::ENV_KEY
        )
      end
    end

    it "adds available probed tools to advertised capabilities" do
      allow(described_class).to receive(:command_result) do |command|
        if command == [ "xcrun", "simctl", "list", "runtimes", "-j" ]
          probe_result(success: true, output: {
            runtimes: [
              { name: "iOS 18.5", version: "18.5", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-5", isAvailable: true, platform: "iOS" }
            ]
          }.to_json)
        else
          probe_result(success: %w[xcodebuild xcrun].include?(command.first))
        end
      end

      with_capability_env(nil) do
        expect(described_class.current.fetch(:capabilities)).to include(
          "toolchain" => [ "xcode" ],
          "runtime" => [ "ios_simulator" ]
        )
      end
    end

    # This guard outlived the plugin that motivated it. Android graders required
    # toolchain=android, nothing in the fleet ever advertised it, and all 51
    # runs in a day came back no_capable_worker -- each one tearing down a
    # merge-train assembly -- until Android support was removed outright. The
    # assertion stays because the shape of that mistake is not Android-specific:
    # core naming a platform's toolchain is what let the capability and the
    # tooling drift apart in the first place.
    # Core owns the mechanism; a plugin owns where its tooling lives. Keeping
    # a toolchain's SDK root and directory layout out of this class is what lets
    # the plugin stay deletable.
    it "advertises a toolchain a plugin probes for" do
      provider = Class.new do
        def self.capability_probes(env: ENV)
          [ { dimension: "toolchain", token: "demo", command: [ "/opt/demo/bin/demo", "--version" ] } ]
        end
      end
      allow(Syrus::PluginRegistry).to receive(:providers_for).with(:worker_capability_probe).and_return([ provider ])
      allow(described_class).to receive(:command_result) do |command|
        probe_result(success: command.first == "/opt/demo/bin/demo")
      end

      with_capability_env(nil) do
        expect(described_class.current.fetch(:capabilities)["toolchain"]).to include("demo")
      end
    end

    it "does not advertise a plugin toolchain whose probe fails" do
      provider = Class.new do
        def self.capability_probes(env: ENV)
          [ { dimension: "toolchain", token: "demo", command: [ "/opt/demo/bin/demo" ] } ]
        end
      end
      allow(Syrus::PluginRegistry).to receive(:providers_for).with(:worker_capability_probe).and_return([ provider ])
      allow(described_class).to receive(:command_result) { probe_result(success: false) }

      with_capability_env(nil) do
        expect(Array(described_class.current.fetch(:capabilities)["toolchain"])).not_to include("demo")
      end
    end

    # A worker that advertises slightly less is recoverable; a worker that will
    # not boot is not.
    it "survives a plugin probe provider that raises" do
      provider = Class.new do
        def self.capability_probes(env: ENV) = raise("boom")
      end
      allow(Syrus::PluginRegistry).to receive(:providers_for).with(:worker_capability_probe).and_return([ provider ])
      allow(described_class).to receive(:command_result) { probe_result(success: false) }

      with_capability_env(nil) do
        expect(described_class.current.fetch(:capabilities)).to include("os", "arch")
      end
    end

    it "ignores a plugin probe naming a dimension core does not model" do
      provider = Class.new do
        def self.capability_probes(env: ENV)
          [ { dimension: "warp_drive", token: "demo", command: [ "/opt/demo/bin/demo" ] } ]
        end
      end
      allow(Syrus::PluginRegistry).to receive(:providers_for).with(:worker_capability_probe).and_return([ provider ])
      allow(described_class).to receive(:command_result) { probe_result(success: true) }

      with_capability_env(nil) do
        expect(described_class.current.fetch(:capabilities)).not_to have_key("warp_drive")
      end
    end

    # No SDK paths, no platform toolchain names in CODE. Comments may still
    # explain why the extension point exists -- prose is documentation, not
    # knowledge core depends on.
    it "keeps platform-specific toolchain knowledge out of core" do
      source = File.read(Rails.root.join("app/services/worker_capabilities.rb"))
      code = source.lines.reject { |line| line.strip.start_with?("#") }.join

      expect(code).not_to match(/android/i)
      expect(code).not_to include("/opt/")
    end

    it "does not advertise the iOS simulator runtime when simctl has no available iOS runtimes" do
      allow(described_class).to receive(:command_result) do |command|
        if command == [ "xcrun", "simctl", "list", "runtimes", "-j" ]
          probe_result(success: true, output: {
            runtimes: [
              { name: "iOS 18.5", version: "18.5", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-5", isAvailable: false, platform: "iOS" }
            ]
          }.to_json)
        else
          probe_result(success: false)
        end
      end

      with_capability_env(nil) do
        payload = described_class.current

        expect(payload.fetch(:diagnostics)).to include(
          "ios_simulator" => true,
          "ios_simulator_runtime_count" => 0
        )
        expect(payload.fetch(:capabilities)).not_to include("runtime")
      end
    end

    it "reports structured iOS toolchain readiness facts without mutating the host" do
      allow(described_class).to receive(:os_token).and_return("macos")
      allow(described_class).to receive(:arch_token).and_return("arm64")
      allow(described_class).to receive(:command_result) do |command|
        case command
        when [ "sw_vers", "-productVersion" ]
          probe_result(success: true, output: "15.6\n")
        when [ "xcodebuild", "-version" ]
          probe_result(success: true, output: "Xcode 16.4\nBuild version 16F6\n")
        when [ "xcode-select", "-p" ]
          probe_result(success: true, output: "/Applications/Xcode.app/Contents/Developer\n")
        when [ "xcrun", "--find", "xcodebuild" ]
          probe_result(success: true, output: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild\n")
        when [ "xcrun", "simctl", "list", "runtimes", "-j" ]
          probe_result(success: true, output: {
            runtimes: [
              { name: "iOS 18.5", version: "18.5", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-5", isAvailable: true, platform: "iOS" },
              { name: "watchOS 11.5", version: "11.5", identifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-5", isAvailable: true, platform: "watchOS" },
              { name: "iOS 17.0", version: "17.0", identifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-0", isAvailable: false, platform: "iOS" }
            ]
          }.to_json)
        when [ "xcrun", "simctl", "list", "devices", "-j" ]
          probe_result(success: true, output: {
            devices: {
              "com.apple.CoreSimulator.SimRuntime.iOS-18-5" => [
                { name: "iPhone 16", udid: "A-UDID", state: "Shutdown", isAvailable: true },
                { name: "iPhone 15", udid: "OLD-UDID", state: "Shutdown", isAvailable: false }
              ],
              "com.apple.CoreSimulator.SimRuntime.watchOS-11-5" => [
                { name: "Apple Watch", udid: "WATCH-UDID", state: "Shutdown", isAvailable: true }
              ]
            }
          }.to_json)
        else
          probe_result(success: false)
        end
      end

      payload = described_class.current

      expect(payload.fetch(:capabilities)).to include(
        "os" => [ "macos" ],
        "arch" => [ "arm64" ],
        "toolchain" => [ "xcode" ],
        "runtime" => [ "ios_simulator" ]
      )
      expect(payload.fetch(:diagnostics)).to include(
        "xcode" => true,
        "ios_simulator" => true,
        "xcode_version" => "16.4",
        "xcode_build_version" => "16F6",
        "developer_dir" => "/Applications/Xcode.app/Contents/Developer",
        "xcode_path" => "/Applications/Xcode.app",
        "xcodebuild_path" => "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
        "command_line_tools_usable" => true,
        "ios_simulator_runtime_count" => 1,
        "ios_simulator_device_count" => 1
      )
      expect(payload.dig(:diagnostics, "host")).to include(
        "macos_version" => "15.6",
        "host_cpu" => kind_of(String)
      )
      expect(payload.dig(:diagnostics, "ios_simulator_runtimes")).to contain_exactly(
        include("name" => "iOS 18.5", "version" => "18.5")
      )
      expect(payload.dig(:diagnostics, "ios_simulator_devices")).to contain_exactly(
        include("name" => "iPhone 16", "udid" => "A-UDID")
      )
    end

    it "treats timed out probes as unavailable" do
      allow(described_class).to receive(:capability_probe).and_raise(Timeout::Error)

      with_capability_env(nil) do
        expect(described_class.current.fetch(:diagnostics)).to include(
          "docker" => false,
          "docker_probe_status" => "timed_out",
          "xcode" => false,
          "xcode_probe_status" => "timed_out",
          "ios_simulator" => false,
          "ios_simulator_probe_status" => "timed_out"
        )
      end
    end

    it "distinguishes a missing command from one that ran and failed" do
      allow(described_class).to receive(:command_result) do |command|
        status = command.first == "docker" ? "not_found" : "failed"
        probe_result(success: false, status: status)
      end

      payload = described_class.current

      expect(payload.fetch(:diagnostics)).to include(
        "docker" => false,
        "docker_probe_status" => "not_found",
        "xcode" => false,
        "xcode_probe_status" => "failed"
      )
    end

    it "includes the external worker pool name in diagnostics when configured" do
      previous = ENV["SYRUS_WORKER_POOL_NAME"]
      ENV["SYRUS_WORKER_POOL_NAME"] = "macos-xcode"
      allow(described_class).to receive(:command_result).and_return(probe_result(success: false))

      expect(described_class.current.fetch(:diagnostics)).to include(
        "worker_pool_name" => "macos-xcode"
      )
    ensure
      previous.nil? ? ENV.delete("SYRUS_WORKER_POOL_NAME") : ENV["SYRUS_WORKER_POOL_NAME"] = previous
    end
  end

  describe "probe execution" do
    it "forwards only PATH to every core probe" do
      capture = double(success?: false, stdout: "", stderr: "", result: double(timed_out?: false, exit_status: 1))
      runner = instance_double(ProcessRunner, capture: capture)
      allow(ProcessRunner).to receive(:new).and_return(runner)

      described_class::TOOL_PROBES.each do |probe|
        described_class.send(:command_result, probe.command)
      end

      described_class::TOOL_PROBES.each do |probe|
        expect(ProcessRunner).to have_received(:new).with(
          env: { "PATH" => ENV.fetch("PATH", "") },
          command: probe.command,
          mounts: kind_of(ProcessRunner::Mounts),
          network: "grader",
          timeout: described_class::PROBE_TIMEOUT_SECONDS,
          kind: "runtime_probe"
        )
      end
    end

    it "classifies command lookup and execution failures separately" do
      result = ->(exit_status) { double(timed_out?: false, exit_status: exit_status) }

      allow(described_class).to receive(:capability_probe).and_return(
        double(success?: false, stdout: "", stderr: "", result: result.call(127)),
        double(success?: false, stdout: "", stderr: "", result: result.call(126)),
        double(success?: false, stdout: "", stderr: "", result: result.call(1))
      )

      expect(described_class.send(:command_result, [ "missing" ]).status).to eq("not_found")
      expect(described_class.send(:command_result, [ "unusable" ]).status).to eq("not_executable")
      expect(described_class.send(:command_result, [ "failing" ]).status).to eq("failed")
    end
  end

  describe ".queue_names_for" do
    it "keeps Linux workers on the broad queue plus their default architecture partition" do
      expect(described_class.queue_names_for("runs", capabilities: { "os" => [ "linux" ] }))
        .to eq(%w[runs runs-linux-amd64])
    end

    it "keeps macOS workers off the broad Linux queue without requiring architecture labels" do
      expect(described_class.queue_names_for("runs", capabilities: { "os" => [ "macos" ] }))
        .to eq(%w[runs-macos-arm64])
    end

    it "uses explicit architecture labels in capability queues" do
      expect(described_class.queue_names_for("runs", capabilities: { "os" => [ "macos" ], "arch" => [ "x86_64" ] }))
        .to eq(%w[runs-macos-amd64])
    end

    it "drops unsupported Windows worker advertisements" do
      expect(described_class.queue_names_for("merges", capabilities: { "os" => [ "windows" ], "arch" => [ "x64" ] }))
        .to eq(%w[merges])
    end
  end

    it "records plugin probe diagnostics and honors its verification timeout" do
      provider = Class.new do
        def self.capability_probes(env: ENV)
          [ {
            dimension: "runtime", token: "confined", command: [ "/opt/probe" ],
            diagnostics: { "configuration" => "complete" }, timeout: 17
          } ]
        end
      end
      allow(Syrus::PluginRegistry).to receive(:providers_for).with(:worker_capability_probe).and_return([ provider ])
      capture = double(success?: true, stdout: "", stderr: "", result: double(timed_out?: false, exit_status: 0))
      allow(described_class).to receive(:capability_probe).and_return(capture)

      payload = described_class.current

      expect(described_class).to have_received(:capability_probe).with([ "/opt/probe" ], timeout: 17)
      expect(payload.fetch(:diagnostics)).to include("configuration" => "complete")
      expect(payload.fetch(:capabilities).fetch("runtime")).to include("confined")
    end
end
