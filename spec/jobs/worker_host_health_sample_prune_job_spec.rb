require "rails_helper"

RSpec.describe WorkerHostHealthSamplePruneJob do
  it "keeps retention bounded while preserving samples inside the window" do
    freeze_time do
      old = WorkerHostHealthSample.create!(
        hostname: "worker-a",
        role: "worker",
        version: "abc",
        observed_at: (WorkerHostHealthSample::RETAIN_AFTER + 1.second).ago
      )
      boundary = WorkerHostHealthSample.create!(
        hostname: "worker-b",
        role: "worker",
        version: "abc",
        observed_at: WorkerHostHealthSample::RETAIN_AFTER.ago
      )
      fresh = WorkerHostHealthSample.create!(
        hostname: "worker-c",
        role: "worker",
        version: "abc",
        observed_at: 1.hour.ago
      )

      described_class.perform_now

      expect(WorkerHostHealthSample.exists?(old.id)).to be(false)
      expect(WorkerHostHealthSample.exists?(boundary.id)).to be(true)
      expect(WorkerHostHealthSample.exists?(fresh.id)).to be(true)
    end
  end
end
