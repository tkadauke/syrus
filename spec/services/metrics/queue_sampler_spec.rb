require "rails_helper"

# Two boundaries are replaced here because the test environment cannot provide
# them, not because they are inconvenient:
#
#   * the queue database. Tests run single-database, so the solid_queue_* tables
#     do not exist (see CLAUDE.md). Metrics::QueueSource is the seam that holds
#     every query needing them; it is deliberately thin, and its SQL is not
#     exercised here. The association names it relies on
#     (ready/claimed/blocked/scheduled/failed_execution) were read off the
#     installed solid_queue gem, and the aggregate shapes were run against
#     production while this was written.
#   * Rails.cache, which is :null_store in test -- writes are dropped and reads
#     return nil, so a cache round-trip cannot be observed without a real store.
RSpec.describe Metrics::QueueSampler do
  # A stand-in for Metrics::QueueSource. A plain object rather than a verifying
  # double because instantiating the real one loads AR schema for tables that
  # are not there.
  class FakeQueueSource
    attr_writer :ready_counts, :oldest_ready_at, :claimed_counts,
                :blocked_count, :failed_counts, :orphaned_rows

    def initialize
      @ready_counts = {}
      @oldest_ready_at = {}
      @claimed_counts = {}
      @blocked_count = 0
      @failed_counts = {}
      @orphaned_rows = 0
    end

    def ready_counts = resolve(@ready_counts)
    def oldest_ready_at = resolve(@oldest_ready_at)
    def claimed_counts = resolve(@claimed_counts)
    def blocked_count = resolve(@blocked_count)
    def failed_counts = resolve(@failed_counts)
    def orphaned_rows = resolve(@orphaned_rows)

    private

    # Lets a spec set an exception to have it raised, so degradation is testable.
    def resolve(value)
      raise value if value.is_a?(Exception)

      value
    end
  end

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:source) { FakeQueueSource.new }

  # The registry is process-global: reset so one example's gauges cannot be read
  # as another's, and restore afterwards so later specs -- including the catalog
  # drift guard -- do not see a registry stripped to this one class's metrics.
  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    described_class.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  describe "#sample!" do
    it "caches a sample the scrape path can render without querying the queue" do
      source.ready_counts = { "polling" => 2715 }
      source.blocked_count = 1787
      source.orphaned_rows = 553_671

      payload = described_class.sample!(source: source)

      expect(payload[:ready]).to eq({ "polling" => 2715 })
      expect(payload[:blocked]).to eq(1787)
      expect(payload[:orphaned]).to eq(553_671)
      expect(cache.read(described_class::CACHE_KEY)).to eq(payload)
    end

    it "converts the oldest ready job's timestamp into an age" do
      source.oldest_ready_at = { "polling" => 190.minutes.ago }

      expect(described_class.sample!(source: source)[:oldest_age]["polling"]).to be_within(5).of(11_400)
    end

    # Best-effort by design: a queue table that cannot be read must not take
    # down the recurring job, and the gauge it could not fill simply does not
    # appear rather than reporting a misleading zero.
    it "degrades one failing query without losing the rest of the sample" do
      source.ready_counts = ActiveRecord::StatementInvalid.new("no such table")
      source.blocked_count = 42

      payload = nil
      expect { payload = described_class.sample!(source: source) }.not_to raise_error
      expect(payload[:ready]).to eq({})
      expect(payload[:blocked]).to eq(42)
    end
  end

  describe "#refresh_gauges!" do
    it "sets gauges from the cached sample" do
      cache.write(described_class::CACHE_KEY, {
        sampled_at: Time.current,
        ready: { "polling" => 2715 },
        oldest_age: { "polling" => 11_400 },
        claimed: { "runs" => 3 },
        blocked: 1787,
        failed: { "PollPullRequestJob" => 3318 },
        orphaned: 553_671
      })

      expect(described_class.refresh_gauges!(source: source)).to be(true)

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_global_queue_ready_count{queue="polling"} 2715')
      expect(rendered).to include('syrus_global_queue_oldest_age_seconds{queue="polling"} 11400')
      expect(rendered).to include('syrus_global_queue_claimed_count{queue="runs"} 3')
      expect(rendered).to include('syrus_global_queue_failed_count{job_class="PollPullRequestJob"} 3318')
      expect(rendered).to include("syrus_global_queue_blocked_count 1787")
      expect(rendered).to include("syrus_global_queue_orphaned_rows 553671")
    end

    # If the sampler stops, these gauges would otherwise keep reporting whatever
    # they last saw -- confidently showing a healthy queue during exactly the
    # incident they exist to catch. The published sample age makes that
    # detectable; the cache TTL eventually makes it stop lying entirely.
    it "publishes the age of the sample so staleness is assertable" do
      cache.write(described_class::CACHE_KEY, {
        sampled_at: 5.minutes.ago, ready: {}, oldest_age: {}, claimed: {},
        blocked: 0, failed: {}, orphaned: 0
      })

      described_class.refresh_gauges!(source: source)

      age = Syrus::Metrics.render[/syrus_global_queue_sample_age_seconds (\d+)/, 1].to_i
      expect(age).to be_within(5).of(300)
    end

    it "reports nothing rather than zeroes when no sample has been taken" do
      expect(described_class.refresh_gauges!(source: source)).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_global_queue_ready_count{")
    end
  end
end
