require "rails_helper"

RSpec.describe ScheduledTasks::Callbacks do
  describe ".on_tick" do
    it "enqueues the scheduled task poll" do
      expect { described_class.on_tick }.to have_enqueued_job(PollScheduledTasksJob)
    end

    it "samples the autopaused metric" do
      expect(ScheduledTasks::MetricsSampler).to receive(:sample!)

      described_class.on_tick
    end

    it "still enqueues the poll when sampling the metric fails" do
      allow(ScheduledTasks::MetricsSampler).to receive(:sample!).and_raise(StandardError, "boom")

      expect { described_class.on_tick }.to have_enqueued_job(PollScheduledTasksJob)
    end
  end

  describe ".on_metrics_scrape" do
    it "refreshes the gauge" do
      expect(ScheduledTasks::MetricsSampler).to receive(:refresh_gauges!)

      described_class.on_metrics_scrape
    end
  end
end
