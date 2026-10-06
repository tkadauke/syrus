require "rails_helper"

RSpec.describe TargetGraph::ExecutionCapabilities do
  it "normalizes values by dimension" do
    capabilities = described_class.new(os: "macOS")

    expect(capabilities.to_h).to eq("os" => [ "macos" ])
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
    expect { described_class.new(os: "linux", toolchains: [ "ruby" ]) }
      .to raise_error(ArgumentError, /unknown keyword: :toolchains/)
  end

  it "merges matching OS capabilities" do
    imported = described_class.new(os: "linux")
    overlay = described_class.new(os: "linux")

    expect(imported.merge(overlay).to_h).to eq("os" => [ "linux" ])
  end

  it "rejects conflicting constrained dimensions when merging" do
    imported = described_class.new(os: "linux")
    overlay = described_class.new(os: "macos")

    expect { imported.merge(overlay) }
      .to raise_error(ArgumentError, /os: imported values \["linux"\] conflict with overlay values \["macos"\]/)
  end
end
