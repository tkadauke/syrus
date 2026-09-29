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
end
