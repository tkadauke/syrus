require "rails_helper"

RSpec.describe Metrics::ClusterCounters do
  around do |example|
    original_registry = Syrus::Metrics.registry
    original_sink = Syrus::Metrics.cluster_sink
    Syrus::Metrics.reset!
    Syrus::Metrics.declare do
      counter :things_total, tags: %i[outcome], cluster: true, comment: "things"
      counter :local_total, tags: %i[outcome], comment: "local only"
    end
    Syrus::Metrics.cluster_sink = Metrics::ClusterCounters
    Metrics::ClusterCounters.reset!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original_registry)
    Syrus::Metrics.cluster_sink = original_sink
  end

  def total(outcome)
    MetricCounterTotal.find_by(name: "syrus_things_total", labels_digest: Digest::SHA256.hexdigest({ "outcome" => outcome }.to_json))&.value
  end

  it "adds each process's increments to one total per series" do
    counter = Syrus::Metrics.counter(:syrus_things_total)
    3.times { counter.increment(tags: { outcome: "answered" }) }
    counter.increment(tags: { outcome: "error" })

    expect(described_class.flush!).to eq(2)
    expect(total("answered")).to eq(3)

    # Another process flushing the same series adds to it rather than
    # overwriting it: the increment happens in the database.
    described_class.record(:syrus_things_total, { outcome: "answered" }, 5)
    described_class.flush!

    expect(total("answered")).to eq(8)
    expect(total("error")).to eq(1)
  end

  it "only sends counters declared cluster: true" do
    Syrus::Metrics.counter(:syrus_local_total).increment(tags: { outcome: "answered" })

    expect(described_class.flush!).to eq(0)
  end

  it "keeps a failed flush's deltas for the next one" do
    described_class.record(:syrus_things_total, { outcome: "answered" }, 2)
    allow(MetricCounterTotal).to receive(:upsert_all).and_raise(ActiveRecord::StatementInvalid, "database gone")

    expect(described_class.flush!).to eq(0)

    allow(MetricCounterTotal).to receive(:upsert_all).and_call_original
    described_class.record(:syrus_things_total, { outcome: "answered" }, 1)
    described_class.flush!

    expect(total("answered")).to eq(3)
  end

  it "never lets recording fail the caller" do
    allow(described_class).to receive(:record).and_raise(StandardError, "boom")

    expect { Syrus::Metrics.counter(:syrus_things_total).increment(tags: { outcome: "answered" }) }.not_to raise_error
  end

  describe Metrics::ClusterCounterSampler do
    around do |example|
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = original
    end

    def rendered_value
      Syrus::Metrics.counter(:syrus_things_total).samples.to_h.find { |labels, _| labels[:outcome] == "answered" }&.last
    end

    it "brings the cluster total into the process serving /metrics" do
      Metrics::ClusterCounters.record(:syrus_things_total, { outcome: "answered" }, 7)
      Metrics::ClusterCounters.flush!

      described_class.sample!
      described_class.refresh_gauges!

      expect(rendered_value).to eq(7.0)
    end

    # This process may have counted increments it has not flushed yet; the
    # cluster total must never pull its series backwards.
    it "never lowers a series" do
      # Counted here but not yet flushed (the sink is bypassed to model that).
      Syrus::Metrics.cluster_sink = nil
      Syrus::Metrics.counter(:syrus_things_total).increment(by: 10, tags: { outcome: "answered" })
      Syrus::Metrics.cluster_sink = Metrics::ClusterCounters
      Metrics::ClusterCounters.record(:syrus_things_total, { outcome: "answered" }, 4)
      Metrics::ClusterCounters.flush!

      described_class.sample!
      described_class.refresh_gauges!

      expect(rendered_value).to eq(10)
    end
  end

  it "may only be declared on counters" do
    definition = Syrus::Metrics::Definition.new(name: :syrus_bad_gauge, type: :gauge, cluster: true)

    expect { definition.validate! }.to raise_error(Syrus::Metrics::Error, /only a counter/)
  end
end
