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
      refreshed_at = 1.minute.from_now.change(usec: 0)

      snapshot = described_class.write(
        items: [ { "kind" => "stuck" } ],
        captured_at: refreshed_at,
        force: true
      )

      expect(Rails.cache).to have_received(:write).once
      expect(snapshot.captured_at).to eq(refreshed_at)
    end
  end

  describe ".clear!" do
    it "removes the cached stuck snapshot so the next read starts empty" do
      described_class.write(items: [ { "kind" => "stuck" } ], captured_at: Time.current, force: true)

      described_class.clear!

      expect(described_class.read.items).to eq([])
      expect(described_class.read.captured_at).to be_nil
    end
  end
end
