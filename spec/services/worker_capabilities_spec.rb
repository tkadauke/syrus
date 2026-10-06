require "rails_helper"

RSpec.describe WorkerCapabilities do
  def with_capability_env(value)
    previous = ENV[described_class::ENV_KEY]
    value.nil? ? ENV.delete(described_class::ENV_KEY) : ENV[described_class::ENV_KEY] = value
    yield
  ensure
    previous.nil? ? ENV.delete(described_class::ENV_KEY) : ENV[described_class::ENV_KEY] = previous
  end

  describe ".parse" do
    it "normalizes comma and space separated capability dimensions" do
      expect(described_class.parse("os:macos,arch:arm64 toolchain:xcode,runtime:ios_simulator,feature:docker")).to eq(
        "os" => [ "macos" ],
        "arch" => [ "arm64" ],
        "toolchains" => [ "xcode" ],
        "runtimes" => [ "ios_simulator" ],
        "features" => [ "docker" ]
      )
    end

    it "drops blank and unknown dimensions" do
      expect(described_class.parse("os:linux,unknown:value,bad")).to eq("os" => [ "linux" ])
    end
  end

  describe ".normalize" do
    it "rejects non-hash capability values with a controlled error" do
      expect {
        described_class.normalize("macos")
      }.to raise_error(ArgumentError, "worker capabilities must be a Hash or TargetGraph::ExecutionCapabilities")
    end
  end

  describe ".current" do
    it "lets configured constrained dimensions override detected defaults" do
      allow(described_class).to receive(:command_available?).and_return(false)

      with_capability_env("os:macos,arch:arm64,toolchain:xcode") do
        payload = described_class.current

        expect(payload.fetch(:capabilities)).to include(
          "os" => [ "macos" ],
          "arch" => [ "arm64" ],
          "toolchains" => [ "xcode" ]
        )
        expect(payload.fetch(:diagnostics)).to include(
          "configured" => true,
          "env_key" => described_class::ENV_KEY
        )
      end
    end

    it "adds common tool capabilities when probes succeed" do
      allow(described_class).to receive(:command_available?) do |command|
        command.first == "docker"
      end

      with_capability_env(nil) do
        expect(described_class.current.fetch(:capabilities)).to include(
          "features" => [ "docker" ]
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
    it "keeps Linux workers on the broad queue plus their architecture partition" do
      expect(described_class.queue_names_for("runs", capabilities: { "os" => [ "linux" ], "arch" => [ "x86_64" ] }))
        .to eq(%w[runs runs-linux-amd64])
    end

    it "keeps macOS workers off the broad Linux queue" do
      expect(described_class.queue_names_for("runs", capabilities: { "os" => [ "macos" ], "arch" => [ "arm64" ] }))
        .to eq(%w[runs-macos-arm64])
    end

    it "normalizes Windows x64 workers to the amd64 queue suffix" do
      expect(described_class.queue_names_for("merges", capabilities: { "os" => [ "windows" ], "arch" => [ "x64" ] }))
        .to eq(%w[merges-windows-amd64])
    end
  end
end
