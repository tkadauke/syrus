require "rails_helper"

RSpec.describe WorkerCapabilities do
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
      allow(described_class).to receive(:command_available?).and_return(true)

      3.times { described_class.current }

      expect(described_class).to have_received(:command_available?)
        .at_most(described_class::TOOL_PROBES.size).times
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
      allow(described_class).to receive(:command_available?).and_return(false)

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
      allow(described_class).to receive(:command_available?) do |command|
        %w[xcodebuild xcrun].include?(command.first)
      end

      with_capability_env(nil) do
        expect(described_class.current.fetch(:capabilities)).to include(
          "toolchain" => [ "xcode" ],
          "runtime" => [ "ios_simulator" ]
        )
      end
    end

    it "treats timed out probes as unavailable" do
      allow(Open3).to receive(:capture2e).and_raise(Timeout::Error)

      with_capability_env(nil) do
        expect(described_class.current.fetch(:diagnostics)).to include(
          "docker" => false,
          "xcode" => false,
          "ios_simulator" => false
        )
      end
    end

    it "includes the external worker pool name in diagnostics when configured" do
      previous = ENV["SYRUS_WORKER_POOL_NAME"]
      ENV["SYRUS_WORKER_POOL_NAME"] = "macos-xcode"
      allow(described_class).to receive(:command_available?).and_return(false)

      expect(described_class.current.fetch(:diagnostics)).to include(
        "worker_pool_name" => "macos-xcode"
      )
    ensure
      previous.nil? ? ENV.delete("SYRUS_WORKER_POOL_NAME") : ENV["SYRUS_WORKER_POOL_NAME"] = previous
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
end
