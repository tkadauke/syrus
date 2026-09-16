require "rails_helper"

# Counter#reconcile!/Histogram#reconcile! exist for exactly one situation:
# an externally computed absolute total (from a cache-mediated sampler, see
# Metrics::LandingSampler) needs to become this process's tracked value,
# without the double-counting a plain #increment/#observe replay would cause
# if applied more than once against the same cached snapshot.
RSpec.describe "Syrus::Metrics reconcile!" do
  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    example.run
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  describe "Counter#reconcile!" do
    before { Syrus::Metrics.declare { counter :reconciled_total, tags: %i[state] } }

    let(:counter) { Syrus::Metrics.counter(:syrus_reconciled_total) }

    it "overwrites the tracked value to the given absolute total" do
      counter.reconcile!(5, tags: { state: "succeeded" })

      expect(Syrus::Metrics.render).to include('syrus_reconciled_total{state="succeeded"} 5')
    end

    it "is idempotent -- applying the same total again does not double it" do
      counter.reconcile!(5, tags: { state: "succeeded" })
      counter.reconcile!(5, tags: { state: "succeeded" })

      expect(Syrus::Metrics.render).to include('syrus_reconciled_total{state="succeeded"} 5')
    end

    it "advances to a larger total on a later tick" do
      counter.reconcile!(5, tags: { state: "succeeded" })
      counter.reconcile!(9, tags: { state: "succeeded" })

      expect(Syrus::Metrics.render).to include('syrus_reconciled_total{state="succeeded"} 9')
    end

    # A stale or reset upstream source (cache eviction, a fresh install) must
    # never make a Prometheus counter appear to shrink.
    it "never moves the value backward" do
      counter.reconcile!(9, tags: { state: "succeeded" })
      counter.reconcile!(2, tags: { state: "succeeded" })

      expect(Syrus::Metrics.render).to include('syrus_reconciled_total{state="succeeded"} 9')
    end

    it "catches a fresh process straight up to the known total in one call" do
      counter.reconcile!(42, tags: { state: "succeeded" })

      expect(Syrus::Metrics.render).to include('syrus_reconciled_total{state="succeeded"} 42')
    end
  end

  describe "Histogram#reconcile!" do
    before { Syrus::Metrics.declare { histogram :reconciled_seconds, buckets: [ 1, 5 ] } }

    let(:histogram) { Syrus::Metrics.histogram(:syrus_reconciled_seconds) }
    let(:snapshot) { { buckets: { 1.0 => 1, 5.0 => 2 }, sum: 8.5, count: 3 } }

    it "overwrites the tracked distribution to the given absolute snapshot" do
      histogram.reconcile!(snapshot)

      output = Syrus::Metrics.render
      expect(output).to include('syrus_reconciled_seconds_bucket{le="1"} 1')
      expect(output).to include('syrus_reconciled_seconds_bucket{le="5"} 2')
      expect(output).to include("syrus_reconciled_seconds_sum 8.5")
      expect(output).to include("syrus_reconciled_seconds_count 3")
    end

    it "is idempotent -- applying the same snapshot again does not double it" do
      histogram.reconcile!(snapshot)
      histogram.reconcile!(snapshot)

      expect(Syrus::Metrics.render).to include("syrus_reconciled_seconds_count 3")
    end

    it "never moves the count backward" do
      histogram.reconcile!(snapshot)
      histogram.reconcile!({ buckets: { 1.0 => 0, 5.0 => 1 }, sum: 1.0, count: 1 })

      expect(Syrus::Metrics.render).to include("syrus_reconciled_seconds_count 3")
    end
  end
end
