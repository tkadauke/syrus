require "rails_helper"

RSpec.describe TargetGraph::ExecutionCapabilities do
  it "normalizes values by dimension" do
    capabilities = described_class.new(
      os: "macOS",
      arch: "ARM64",
      toolchain: "Xcode",
      runtime: "iOS_Simulator"
    )

    expect(capabilities.to_h).to eq(
      "os" => [ "macos" ],
      "arch" => [ "arm64" ],
      "toolchain" => [ "xcode" ],
      "runtime" => [ "ios_simulator" ]
    )
  end

  it "rejects unsupported OS values" do
    expect { described_class.new(os: [ "windows" ]) }
      .to raise_error(ArgumentError, /os: values must be one of linux, macos/)
  end

  it "rejects multiple OS values" do
    expect { described_class.new(os: [ "linux", "macos" ]) }
      .to raise_error(ArgumentError, /os: choose exactly one of linux, macos/)
  end

  it "rejects unsupported dimensions" do
    expect { described_class.new(os: "linux", feature: [ "docker" ]) }
      .to raise_error(ArgumentError, /unknown keyword: :feature/)
  end

  it "merges matching capabilities" do
    imported = described_class.new(os: "macos", arch: "arm64", toolchain: "xcode")
    overlay = described_class.new(os: "macos", arch: "arm64", runtime: "ios_simulator")

    expect(imported.merge(overlay).to_h).to eq(
      "os" => [ "macos" ],
      "arch" => [ "arm64" ],
      "toolchain" => [ "xcode" ],
      "runtime" => [ "ios_simulator" ]
    )
  end

  it "rejects conflicting constrained dimensions when merging" do
    imported = described_class.new(os: "macos", runtime: "ios_simulator")
    overlay = described_class.new(os: "macos", runtime: "visionos_simulator")

    expect { imported.merge(overlay) }
      .to raise_error(ArgumentError, /runtime: imported values \["ios_simulator"\] conflict with overlay values \["visionos_simulator"\]/)
  end
end
