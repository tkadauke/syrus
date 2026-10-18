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

  it "combines distinct process-shaped flushes exactly once" do
    web = described_class::Batch.new(
      identity: "web-process", sequence: 1,
      deltas: { [ "syrus_things_total", { "outcome" => "answered" } ] => 2 }
    )
    worker = described_class::Batch.new(
      identity: "worker-process", sequence: 1,
      deltas: { [ "syrus_things_total", { "outcome" => "answered" } ] => 5 }
    )

    described_class.send(:write, web)
    described_class.send(:write, worker)
    described_class.send(:write, web) # ambiguous committed retry
    described_class.send(:write, worker)

    expect(total("answered")).to eq(7)
  end

  it "only sends counters declared cluster: true" do
    Syrus::Metrics.counter(:syrus_local_total).increment(tags: { outcome: "answered" })

    expect(described_class.flush!).to eq(0)
  end

  it "keeps a failed flush's deltas for the next one" do
    described_class.record(:syrus_things_total, { outcome: "answered" }, 2)
    allow(MetricCounterTotal).to receive(:upsert_all).and_raise(ActiveRecord::StatementInvalid, "database gone")

    expect(described_class.flush!).to eq(0)
    expect(described_class.capture_status).to eq("partial")

    allow(MetricCounterTotal).to receive(:upsert_all).and_call_original
    described_class.record(:syrus_things_total, { outcome: "answered" }, 1)
    described_class.flush!

    expect(total("answered")).to eq(3)
    expect(described_class.capture_status).to eq("available")
  end

  it "does not double-apply a batch when the client observes an error after commit" do
    described_class.record(:syrus_things_total, { outcome: "answered" }, 2)
    first_attempt = true
    allow(described_class).to receive(:write).and_wrap_original do |original, batch|
      applied = original.call(batch)
      if first_attempt
        first_attempt = false
        raise ActiveRecord::ConnectionNotEstablished, "connection lost after commit"
      end
      applied
    end

    expect(described_class.flush!).to eq(0)
    expect(total("answered")).to eq(2)

    expect(described_class.flush!).to eq(0)
    expect(total("answered")).to eq(2)
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

    it "does not reapply a cached snapshot after a process registry reset" do
      Metrics::ClusterCounters.record(:syrus_things_total, { outcome: "answered" }, 7)
      Metrics::ClusterCounters.flush!
      described_class.sample!
      described_class.refresh_gauges!

      Syrus::Metrics.reset!
      Syrus::Metrics.declare { counter :things_total, tags: %i[outcome], cluster: true, comment: "things" }
      2.times { described_class.refresh_gauges! }

      expect(rendered_value).to eq(7.0)
      expect(total("answered")).to eq(7)
    end

    it "reports an expired or missing shared snapshot as unavailable" do
      expect(described_class.capture_status).to eq("unavailable")
      described_class.sample!
      expect(described_class.capture_status).to eq("available")
    end

    it "reports a fresh contributor with a failed flush as partial" do
      MetricCounterContributor.create!(
        identity: "failing-worker", last_applied_sequence: 1,
        last_success_at: 1.minute.ago, last_error_at: Time.current
      )

      described_class.sample!

      expect(described_class.capture_status).to eq("partial")
    end

    it "reports a missed heartbeat as partial, then ages out a disappeared process" do
      now = Time.current
      contributor = MetricCounterContributor.create!(
        identity: "disappeared-worker", last_applied_sequence: 1,
        last_success_at: now - 1.minute, updated_at: now - 1.minute
      )

      expect(Metrics::ClusterCounters.capture_status(now: now)).to eq("partial")

      contributor.update_columns(updated_at: now - 6.minutes)
      expect(Metrics::ClusterCounters.capture_status(now: now)).to eq("available")
    end
  end

  it "may only be declared on counters" do
    definition = Syrus::Metrics::Definition.new(name: :syrus_bad_gauge, type: :gauge, cluster: true)

    expect { definition.validate! }.to raise_error(Syrus::Metrics::Error, /only a counter/)
  end
end
