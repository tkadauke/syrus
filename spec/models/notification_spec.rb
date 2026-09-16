require "rails_helper"

RSpec.describe Notification do
  it "exposes unread and recent scopes" do
    user = Factories.user
    old = described_class.create!(user: user, kind: "job_failed", body: "Old", created_at: 2.days.ago)
    read = described_class.create!(user: user, kind: "pr_merged", body: "Read", read_at: 1.hour.ago, created_at: 1.day.ago)
    fresh = described_class.create!(user: user, kind: "job_implemented", body: "Fresh", created_at: 1.hour.ago)

    expect(described_class.unread).to contain_exactly(old, fresh)
    expect(described_class.recent).to eq([ fresh, read, old ])
  end

  describe ".prunable scope" do
    it "includes notifications older than the retention window" do
      user = Factories.user
      old = described_class.create!(user: user, kind: "job_failed", body: "Old", created_at: (described_class.retention_window + 1.day).ago)
      fresh = described_class.create!(user: user, kind: "job_failed", body: "Fresh", created_at: 1.hour.ago)

      expect(described_class.prunable).to include(old)
      expect(described_class.prunable).not_to include(fresh)
    end

    it "returns none when retention is set to 0 (infinite)" do
      AppSetting.current.update!(notification_retention_days: 0)
      user = Factories.user
      old = described_class.create!(user: user, kind: "job_failed", body: "Old", created_at: 10.years.ago)

      expect(described_class.prunable).to be_empty
      expect(described_class.exists?(old.id)).to be true
    end
  end
end
