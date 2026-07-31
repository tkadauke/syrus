require "rails_helper"

RSpec.describe WorkerHostHealthSamplePruneJob do
  it "deletes samples older than the retention window" do
    old = WorkerHostHealthSample.create!(
      hostname: "worker-a",
      role: "worker",
      version: "abc",
      observed_at: (WorkerHostHealthSample::RETAIN_AFTER + 1.day).ago
    )
    fresh = WorkerHostHealthSample.create!(
      hostname: "worker-b",
      role: "worker",
      version: "abc",
      observed_at: 1.hour.ago
    )

    described_class.perform_now

    expect(WorkerHostHealthSample.exists?(old.id)).to be(false)
    expect(WorkerHostHealthSample.exists?(fresh.id)).to be(true)
  end
end
