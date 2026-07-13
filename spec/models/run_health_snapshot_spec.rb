require "rails_helper"

RSpec.describe RunHealthSnapshot, type: :model do
  let(:run) { Factories.run }

  def snapshot(created_at: Time.current, **attrs)
    described_class.create!(
      { run: run, health_status: "healthy", run_state: "running", created_at: created_at }.merge(attrs)
    )
  end

  describe ".ordered scope" do
    it "returns snapshots in ascending created_at order" do
      s1 = snapshot(created_at: 2.hours.ago)
      s2 = snapshot(created_at: 1.hour.ago)
      s3 = snapshot(created_at: 30.minutes.ago)

      expect(described_class.ordered.to_a).to eq([ s1, s2, s3 ])
    end
  end

  describe ".prunable scope" do
    it "includes snapshots older than the retention window" do
      old = snapshot(created_at: (RunHealthSnapshot::RETAIN_AFTER + 1.day).ago)
      fresh = snapshot(created_at: 1.hour.ago)

      expect(described_class.prunable).to include(old)
      expect(described_class.prunable).not_to include(fresh)
    end
  end

  describe "RETAIN_AFTER constant" do
    it "is 7 days" do
      expect(RunHealthSnapshot::RETAIN_AFTER).to eq(7.days)
    end
  end

  describe "HEALTH_STATUSES constant" do
    it "includes healthy, warning, and critical" do
      expect(RunHealthSnapshot::HEALTH_STATUSES).to match_array(%w[healthy warning critical])
    end
  end
end
