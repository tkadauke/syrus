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
      old = sample(observed_at: (described_class.retention_window + 1.day).ago)
      fresh = sample(observed_at: 1.hour.ago, hostname: "worker-b")

      expect(described_class.prunable).to include(old)
      expect(described_class.prunable).not_to include(fresh)
    end

    it "returns none when retention is set to 0 (infinite)" do
      AppSetting.current.update!(worker_host_health_sample_retention_days: 0)
      old = sample(observed_at: 10.years.ago)

      expect(described_class.prunable).to be_empty
      expect(described_class.exists?(old.id)).to be true
    end
  end

  describe ".retention_floor" do
    it "clamps to now minus the configured window" do
      freeze_time do
        expect(described_class.retention_floor(now: Time.current)).to eq(Time.current - described_class.retention_window)
      end
    end

    it "returns the epoch when retention is set to 0 (infinite)" do
      AppSetting.current.update!(worker_host_health_sample_retention_days: 0)

      expect(described_class.retention_floor(now: Time.current)).to eq(Time.at(0))
    end
  end
end
