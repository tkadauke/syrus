require "rails_helper"

RSpec.describe SccacheStatsSummary do
  describe ".for" do
    it "extracts flat integer hit/miss counters and computes hit rate" do
      summary = described_class.for({ "cache_hits" => 8, "cache_misses" => 2, "cache_size" => 1024, "max_cache_size" => 4096, "cache_location" => "S3, bucket: syrus-build-cache" })

      expect(summary.hits).to eq(8)
      expect(summary.misses).to eq(2)
      expect(summary.hit_rate).to eq(80.0)
      expect(summary.cache_size).to eq(1024)
      expect(summary.max_cache_size).to eq(4096)
      expect(summary.cache_location).to eq("S3, bucket: syrus-build-cache")
    end

    it "sums per-language counts when cache_hits/cache_misses are nested count maps" do
      summary = described_class.for({
        "cache_hits" => { "counts" => { "C/C++" => 5, "Rust" => 3 } },
        "cache_misses" => { "counts" => { "C/C++" => 2 } }
      })

      expect(summary.hits).to eq(8)
      expect(summary.misses).to eq(2)
      expect(summary.hit_rate).to eq(80.0)
    end

    it "reads counters nested under a top-level stats key" do
      summary = described_class.for({
        "stats" => { "cache_hits" => 3, "cache_misses" => 1 },
        "cache_size" => 2048
      })

      expect(summary.hits).to eq(3)
      expect(summary.misses).to eq(1)
      expect(summary.cache_size).to eq(2048)
    end

    it "returns nil hit_rate when hits and misses are both zero" do
      summary = described_class.for({ "cache_hits" => 0, "cache_misses" => 0 })

      expect(summary.hit_rate).to be_nil
    end

    it "returns an all-nil summary for a non-hash input" do
      summary = described_class.for("sccache: error: server startup failed")

      expect(summary).to eq(described_class::Summary.new(hits: nil, misses: nil, hit_rate: nil, cache_size: nil, max_cache_size: nil, cache_location: nil))
    end

    it "returns nil counters for an unrecognized cache_hits/cache_misses shape" do
      summary = described_class.for({ "cache_hits" => "n/a", "cache_misses" => [ 1, 2 ] })

      expect(summary.hits).to be_nil
      expect(summary.misses).to be_nil
      expect(summary.hit_rate).to be_nil
    end
  end
end
