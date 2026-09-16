require "rails_helper"

RSpec.describe Syrus::Metrics::SampledGauge do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    Syrus::Metrics.declare { gauge :test_sampled_total }
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def sampler(&block)
    definition = Syrus::Metrics::Definition.new(name: :syrus_test_sampled_total, type: :gauge, sample_block: block)
    described_class.new(definition: definition)
  end

  it "identifies itself by the metric's fully-qualified name" do
    expect(sampler { 1 }.sampler_key).to eq("sampled_gauge:syrus_test_sampled_total")
  end

  describe "#sample!/#refresh_gauges!" do
    it "reports nothing rather than zero when no sample has been taken" do
      expect(sampler { 1 }.refresh_gauges!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_test_sampled_total")
    end

    it "caches the block's return value and sets the gauge from it on refresh" do
      instance = sampler { 42 }
      instance.sample!

      expect(instance.refresh_gauges!).to be(true)
      expect(Syrus::Metrics.render).to include("syrus_test_sampled_total 42")
    end

    it "reflects the latest sample rather than accumulating -- this is a gauge, not a counter" do
      calls = [ 10, 3 ]
      instance = sampler { calls.shift }

      instance.sample!
      instance.refresh_gauges!
      instance.sample!
      instance.refresh_gauges!

      expect(Syrus::Metrics.render).to include("syrus_test_sampled_total 3")
    end

    it "samples a legitimate zero rather than treating it as absent" do
      instance = sampler { 0 }
      instance.sample!

      expect(instance.refresh_gauges!).to be(true)
      expect(Syrus::Metrics.render).to include("syrus_test_sampled_total 0")
    end

    it "does not raise when the sample block itself blows up, and leaves no stale cache entry" do
      instance = sampler { raise "boom" }

      expect { instance.sample! }.not_to raise_error
      expect(instance.refresh_gauges!).to be(false)
    end
  end
end
