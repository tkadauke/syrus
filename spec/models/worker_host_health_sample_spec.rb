require "rails_helper"

RSpec.describe WorkerHostHealthSample, type: :model do
  def sample(observed_at: Time.current, hostname: "worker-a", role: "worker", **attrs)
    described_class.create!({
      hostname: hostname,
      role: role,
      version: "abc123",
      observed_at: observed_at
    }.merge(attrs))
  end

  describe ".ordered scope" do
    it "returns samples in ascending observed_at order" do
      newer = sample(observed_at: 1.minute.ago)
      older = sample(observed_at: 5.minutes.ago, hostname: "worker-b")

      expect(described_class.ordered.to_a).to eq([ older, newer ])
    end
  end

  describe ".prunable scope" do
    it "includes samples older than the retention window" do
      old = sample(observed_at: (described_class::RETAIN_AFTER + 1.day).ago)
      fresh = sample(observed_at: 1.hour.ago, hostname: "worker-b")

      expect(described_class.prunable).to include(old)
      expect(described_class.prunable).not_to include(fresh)
    end
  end

  describe "RETAIN_AFTER constant" do
    it "matches run health snapshot retention" do
      expect(described_class::RETAIN_AFTER).to eq(RunHealthSnapshot::RETAIN_AFTER)
    end
  end
end
