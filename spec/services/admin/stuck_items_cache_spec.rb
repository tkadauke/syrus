require "rails_helper"

RSpec.describe Admin::StuckItemsCache do
  before { Rails.cache.clear }

  describe ".write" do
    it "skips writing unchanged snapshots while the cached value is fresh" do
      cached = described_class::Snapshot.new(
        items: [ { "kind" => "stuck" } ],
        captured_at: Time.current
      )
      allow(described_class).to receive(:read).and_return(cached)
      allow(Rails.cache).to receive(:write).and_call_original

      snapshot = described_class.write(items: [ { "kind" => "stuck" } ], captured_at: 1.minute.from_now)

      expect(Rails.cache).not_to have_received(:write)
      expect(snapshot.captured_at).to eq(cached.captured_at)
    end

    it "forces writes for explicit refreshes" do
      cached = described_class::Snapshot.new(
        items: [ { "kind" => "stuck" } ],
        captured_at: Time.current
      )
      allow(described_class).to receive(:read).and_return(cached)
      allow(Rails.cache).to receive(:write).and_call_original

      snapshot = described_class.write(
        items: [ { "kind" => "stuck" } ],
        captured_at: 1.minute.from_now,
        force: true
      )

      expect(Rails.cache).to have_received(:write).once
      expect(snapshot.captured_at).to be_within(1.second).of(1.minute.from_now)
    end
  end
end
