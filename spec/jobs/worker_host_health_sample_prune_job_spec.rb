require "rails_helper"

RSpec.describe WorkerHostHealthSamplePruneJob do
  it "keeps retention bounded while preserving samples inside the window" do
    freeze_time do
      old = WorkerHostHealthSample.create!(
        hostname: "worker-a",
        role: "worker",
        version: "abc",
        observed_at: (WorkerHostHealthSample.retention_window + 1.second).ago
      )
      boundary = WorkerHostHealthSample.create!(
        hostname: "worker-b",
        role: "worker",
        version: "abc",
        observed_at: WorkerHostHealthSample.retention_window.ago
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

  it "is a no-op when retention is set to 0 (infinite)" do
    AppSetting.current.update!(worker_host_health_sample_retention_days: 0)
    old = WorkerHostHealthSample.create!(hostname: "worker-a", role: "worker", version: "abc", observed_at: 10.years.ago)

    described_class.perform_now

    expect(WorkerHostHealthSample.exists?(old.id)).to be(true)
  end
end
