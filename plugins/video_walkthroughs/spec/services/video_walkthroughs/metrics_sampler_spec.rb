require "rails_helper"

RSpec.describe VideoWalkthroughs::MetricsSampler do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    Syrus::Metrics.declare_plugin("video_walkthroughs") { gauge :storage_bytes }
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  describe ".record_storage_bytes!/.refresh_gauges!" do
    it "reports nothing rather than zero when no sample has been recorded" do
      expect(described_class.refresh_gauges!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_video_walkthroughs_storage_bytes")
    end

    it "sets the gauge to the recorded total once refreshed" do
      described_class.record_storage_bytes!(1_500_000_000)

      expect(described_class.refresh_gauges!).to be(true)
      expect(Syrus::Metrics.render).to include("syrus_video_walkthroughs_storage_bytes 1500000000")
    end

    it "reflects a later recording rather than accumulating -- this is a gauge, not a counter" do
      described_class.record_storage_bytes!(1_000)
      described_class.refresh_gauges!
      described_class.record_storage_bytes!(400)
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include("syrus_video_walkthroughs_storage_bytes 400")
    end
  end
end
