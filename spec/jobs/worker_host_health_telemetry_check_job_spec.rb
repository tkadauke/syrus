require "rails_helper"

RSpec.describe WorkerHostHealthTelemetryCheckJob do
  describe "#perform" do
    it "logs a warning for a live worker with no recent WorkerHostHealthSample rows" do
      InstanceVersion.create!(hostname: "syrus-worker-1", role: "worker", version: "abc",
                               started_at: 1.minute.ago, last_heartbeat_at: 10.seconds.ago)

      expect(Rails.logger).to receive(:warn).with(/syrus-worker-1.*no WorkerHostHealthSample/)

      described_class.perform_now
    end

    it "does not warn for a live worker with a recent sample" do
      InstanceVersion.create!(hostname: "syrus-worker-2", role: "worker", version: "abc",
                               started_at: 1.minute.ago, last_heartbeat_at: 10.seconds.ago)
      WorkerHostHealthSample.create!(hostname: "syrus-worker-2", role: "worker", version: "abc",
                                      observed_at: 1.minute.ago)

      expect(Rails.logger).not_to receive(:warn)

      described_class.perform_now
    end

    it "does not warn for a worker instance that is no longer fresh" do
      InstanceVersion.create!(hostname: "syrus-worker-3", role: "worker", version: "abc",
                               started_at: 10.minutes.ago, last_heartbeat_at: 10.minutes.ago)

      expect(Rails.logger).not_to receive(:warn)

      described_class.perform_now
    end

    it "does not warn about web instances" do
      InstanceVersion.create!(hostname: "syrus-web-1", role: "web", version: "abc",
                               started_at: 1.minute.ago, last_heartbeat_at: 10.seconds.ago)

      expect(Rails.logger).not_to receive(:warn)

      described_class.perform_now
    end

    it "ignores samples older than the stale threshold" do
      InstanceVersion.create!(hostname: "syrus-worker-4", role: "worker", version: "abc",
                               started_at: 1.minute.ago, last_heartbeat_at: 10.seconds.ago)
      WorkerHostHealthSample.create!(hostname: "syrus-worker-4", role: "worker", version: "abc",
                                      observed_at: (described_class::STALE_THRESHOLD + 1.minute).ago)

      expect(Rails.logger).to receive(:warn).with(/syrus-worker-4/)

      described_class.perform_now
    end
  end
end
