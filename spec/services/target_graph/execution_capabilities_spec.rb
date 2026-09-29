require "rails_helper"

RSpec.describe TargetGraph::ExecutionCapabilities do
  it "normalizes values by dimension" do
    capabilities = described_class.new(
      os: "macOS",
      arch: [ "ARM64", "arm64" ],
      toolchains: [ "Xcode" ],
      runtimes: [ "iOS_Simulator" ],
      features: [ "Metal-GPU" ]
    )

    expect(capabilities.to_h).to eq(
      "os" => [ "macos" ],
      "arch" => [ "arm64" ],
      "toolchains" => [ "xcode" ],
      "runtimes" => [ "ios_simulator" ],
      "features" => [ "metal-gpu" ]
    )
  end

  it "rejects conflicting wildcard and specific values" do
    expect { described_class.new(os: [ "any", "linux" ]) }
      .to raise_error(ArgumentError, /"any" cannot be combined/)
  end

  it "merges imported capabilities with additive overlay dimensions" do
    imported = described_class.new(os: "linux", toolchains: [ "ruby" ])
    overlay = described_class.new(toolchains: [ "node" ], runtimes: [ "docker" ])

    expect(imported.merge(overlay).to_h).to eq(
      "os" => [ "linux" ],
      "toolchains" => [ "ruby", "node" ],
      "runtimes" => [ "docker" ]
    )
  end

  it "rejects conflicting constrained dimensions when merging" do
    imported = described_class.new(os: "linux")
    overlay = described_class.new(os: "macos")

    expect { imported.merge(overlay) }
      .to raise_error(ArgumentError, /os: imported values \["linux"\] conflict with overlay values \["macos"\]/)
  end
end
