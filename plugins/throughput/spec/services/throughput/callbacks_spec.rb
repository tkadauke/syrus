require "rails_helper"

RSpec.describe Throughput::Callbacks do
  describe ".on_tick" do
    it "samples the metrics" do
      expect(Throughput::MetricsSampler).to receive(:sample!)

      described_class.on_tick
    end

    it "does not raise when sampling fails" do
      allow(Throughput::MetricsSampler).to receive(:sample!).and_raise(StandardError, "boom")

      expect { described_class.on_tick }.not_to raise_error
    end
  end

  describe ".on_metrics_scrape" do
    it "refreshes the gauges" do
      expect(Throughput::MetricsSampler).to receive(:refresh_gauges!)

      described_class.on_metrics_scrape
    end
  end
end
