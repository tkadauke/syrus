require "rails_helper"

RSpec.describe Calendar::Event do
  let(:attributes) do
    { source_id: "calendar:test", id: "event-1", kind: "test", title: "Test", starts_at: Time.current,
      destination_path: "/test", state: "planned", metadata: {} }
  end

  it "validates timestamps, paths, and cadence structure" do
    expect { described_class.new(**attributes.merge(starts_at: "tomorrow")) }.to raise_error(ArgumentError, /timestamp/)
    expect { described_class.new(**attributes.merge(destination_path: "https://example.test")) }.to raise_error(ArgumentError, /application path/)
    expect { described_class.new(**attributes.merge(cadence: { label: "hourly" })) }.to raise_error(ArgumentError, /cadence/)
  end

  it "rejects timestamps whose ordering is impossible" do
    expect { described_class.new(**attributes.merge(ends_at: 1.hour.ago)) }.to raise_error(ArgumentError, /must not precede/)
  end
end
