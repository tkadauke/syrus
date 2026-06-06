require "rails_helper"

RSpec.describe DataRootDiskUsage do
  describe ".parse_df" do
    it "classifies healthy, warning, and critical usage from df output" do
      healthy = described_class.parse_df(df_output(capacity: "84%", available_kb: 20_000_000), path: "/data")
      warning = described_class.parse_df(df_output(capacity: "85%", available_kb: 20_000_000), path: "/data")
      critical = described_class.parse_df(df_output(capacity: "95%", available_kb: 20_000_000), path: "/data")

      expect(healthy.level).to eq(:ok)
      expect(warning.level).to eq(:warning)
      expect(critical.level).to eq(:critical)
    end

    it "classifies less than 5GB available as critical even below 95 percent" do
      snapshot = described_class.parse_df(df_output(capacity: "80%", available_kb: 4_999_999), path: "/data")

      expect(snapshot.level).to eq(:critical)
      expect(snapshot.available_bytes).to eq(4_999_999.kilobytes)
    end

    it "serializes actionable filesystem detail" do
      travel_to Time.zone.parse("2026-06-05 12:00:00 UTC") do
        snapshot = described_class.parse_df(df_output(capacity: "90%", available_kb: 10_000_000), path: "/syrus-home/.syrus")

        expect(snapshot.as_json).to include(
          path: "/syrus-home/.syrus",
          filesystem: "/dev/pvc",
          total_bytes: 100_000_000.kilobytes,
          used_bytes: 90_000_000.kilobytes,
          available_bytes: 10_000_000.kilobytes,
          used_percent: 90,
          mounted_on: "/syrus-home",
          observed_at: "2026-06-05T12:00:00Z",
          level: "warning"
        )
      end
    end
  end

  describe ".refresh!" do
    it "writes the latest snapshot into the shared cache" do
      snapshot = described_class.parse_df(df_output(capacity: "90%", available_kb: 10_000_000), path: "/data")
      allow(described_class).to receive(:read).and_return(snapshot)

      expect(Rails.cache).to receive(:write).with(described_class::CACHE_KEY, snapshot, expires_in: described_class::CACHE_TTL)

      expect(described_class.refresh!).to eq(snapshot)
    end
  end

  def df_output(capacity:, available_kb:)
    <<~DF
      Filesystem 1024-blocks Used Available Capacity Mounted on
      /dev/pvc 100000000 90000000 #{available_kb} #{capacity} /syrus-home
    DF
  end
end
