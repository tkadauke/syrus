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
  end
end
