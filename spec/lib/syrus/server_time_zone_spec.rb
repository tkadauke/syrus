require "rails_helper"

RSpec.describe Syrus::ServerTimeZone do
  it "prefers an explicit IANA server zone" do
    resolution = described_class.resolve("SYRUS_TIME_ZONE" => "Europe/Berlin", "TZ" => "America/New_York")

    expect(resolution.to_h).to eq(name: "Europe/Berlin", source: "SYRUS_TIME_ZONE")
  end

  it "uses a valid process TZ when no explicit zone is configured" do
    resolution = described_class.resolve("TZ" => "America/New_York")

    expect(resolution.to_h).to eq(name: "America/New_York", source: "TZ")
  end

  it "falls back to Etc/UTC for an invalid ambient TZ" do
    expect(described_class.resolve("TZ" => "localtime").to_h).to eq(name: "Etc/UTC", source: "default")
  end

  it "fails clearly for an invalid explicit zone" do
    expect { described_class.resolve("SYRUS_TIME_ZONE" => "Mars/Olympus") }
      .to raise_error(ArgumentError, /SYRUS_TIME_ZONE must be a valid IANA time zone identifier/)
  end
end
