require "rails_helper"
require "tmpdir"

RSpec.describe PreparedLayerCache do
  around do |example|
    Dir.mktmpdir("syrus-layer-cache-spec") do |dir|
      @data_root = Pathname.new(dir)
      example.run
    end
  end

  before do
    allow(WorkflowWorkspace).to receive(:data_root).and_return(@data_root)
    allow(DataRootDiskUsage).to receive(:current).and_return(snapshot(used_percent: 10))
  end

  it "keys an entry by worker storage key and prepare fingerprint, outside any workflow workspace" do
    path = described_class.path_for(storage_key: "storage-a", fingerprint: "abc123")

    expect(path.to_s).to eq(@data_root.join("prepared-layers", "storage-a", "abc123").to_s)
    expect(path.to_s).not_to include("workflows")
  end

  it "measures an entry once and reports it as reusable afterwards" do
    path = seed_entry("fp1", bytes: 2048)

    described_class.record_use!(path)
    entry = described_class.entries.find { |candidate| candidate.path == path }

    expect(entry.bytes).to be >= 2048
    expect(entry.fingerprint).to eq("fp1")
  end

  describe "eviction" do
    it "evicts least recently used entries until the cache fits its budget" do
      old_entry = seed_entry("old", bytes: 3.megabytes, last_used_at: 5.days.ago)
      middle = seed_entry("middle", bytes: 3.megabytes, last_used_at: 3.days.ago)
      newest = seed_entry("newest", bytes: 3.megabytes, last_used_at: 1.day.ago)

      evicted = with_budget_gb(0.005) { described_class.evict_over_budget! }

      expect(evicted.map { |entry| entry.path.basename.to_s }).to eq([ "old", "middle" ])
      expect(old_entry).not_to exist
      expect(middle).not_to exist
      expect(newest).to exist
    end

    it "never evicts the entry the caller just materialized" do
      keep = seed_entry("keep", bytes: 3.megabytes, last_used_at: 9.days.ago)
      other = seed_entry("other", bytes: 3.megabytes, last_used_at: 8.days.ago)

      with_budget_gb(0.000001) { described_class.evict_over_budget!(keep: keep) }

      expect(keep).to exist
      expect(other).not_to exist
    end

    # A grader run holds no lock across process restarts, so recency stands in
    # for "in use": a sweep only considers entries nothing touched for hours.
    it "leaves recently used entries alone even when over budget" do
      recent = seed_entry("recent", bytes: 3.megabytes, last_used_at: 5.minutes.ago)

      evicted = with_budget_gb(0.000001) { described_class.evict_over_budget! }

      expect(evicted).to be_empty
      expect(recent).to exist
    end

    it "evicts under data root pressure even when the budget would allow it" do
      allow(DataRootDiskUsage).to receive(:current).and_return(snapshot(used_percent: 96))
      stale = seed_entry("stale", bytes: 1.kilobyte, last_used_at: 5.days.ago)

      evicted = with_budget_gb(500) { described_class.evict_over_budget! }

      expect(evicted.map { |entry| entry.path.basename.to_s }).to eq([ "stale" ])
      expect(stale).not_to exist
    end

    it "treats a zero budget as unlimited" do
      stale = seed_entry("stale", bytes: 3.megabytes, last_used_at: 5.days.ago)

      evicted = with_budget_gb(0) { described_class.evict_over_budget! }

      expect(evicted).to be_empty
      expect(stale).to exist
    end
  end

  describe "budget" do
    it "prefers a per-host override over the instance setting" do
      AppSetting.current.update!(prepared_layer_cache_gb: 100)

      expect(with_env("SYRUS_PREPARED_LAYER_CACHE_GB" => "4") { described_class.budget_bytes })
        .to eq(4 * 1024**3)
    end

    it "falls back to the instance setting" do
      AppSetting.current.update!(prepared_layer_cache_gb: 7)

      expect(described_class.budget_bytes).to eq(7 * 1024**3)
    end
  end

  def seed_entry(fingerprint, bytes:, last_used_at: Time.current)
    path = described_class.path_for(storage_key: "storage-a", fingerprint: fingerprint)
    FileUtils.mkdir_p(path)
    path.join("payload.bin").write("x" * bytes)
    path.join(described_class::METADATA_FILENAME)
      .write(JSON.generate("bytes" => bytes, "last_used_at" => last_used_at.iso8601))
    path
  end

  def snapshot(used_percent:)
    DataRootDiskUsage::Snapshot.new(
      path: @data_root.to_s,
      filesystem: "test",
      total_bytes: 100.gigabytes,
      used_bytes: (100.gigabytes * used_percent / 100.0).to_i,
      available_bytes: (100.gigabytes * (100 - used_percent) / 100.0).to_i,
      used_percent: used_percent,
      mounted_on: @data_root.to_s,
      observed_at: Time.current
    )
  end

  def with_budget_gb(gigabytes, &block)
    with_env("SYRUS_PREPARED_LAYER_CACHE_GB" => gigabytes.to_s, &block)
  end

  def with_env(values)
    previous = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
