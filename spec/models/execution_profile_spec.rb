require "rails_helper"

RSpec.describe ExecutionProfile do
  it "keeps macOS desktop distinct from iOS/Xcode" do
    desktop = described_class.fetch("macos_desktop").capabilities
    ios = described_class.fetch("ios_xcode").capabilities

    expect(desktop).to eq("os" => [ "macos" ], "arch" => [ "arm64" ])
    expect(desktop).not_to have_key("toolchain")
    expect(desktop).not_to have_key("runtime")
    expect(ios).to include("toolchain" => [ "xcode" ], "runtime" => [ "ios_simulator" ])
  end

  it "rejects arbitrary classifier profiles" do
    expect { described_class.fetch("macos_with_everything") }.to raise_error(ArgumentError, /unknown execution profile/)
  end
end
