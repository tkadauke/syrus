require "rails_helper"

RSpec.describe MetricsDashboard::Sample do
  def sample(recorded_at:, metric: "m", series_key: SecureRandom.hex(4))
    described_class.create!(metric: metric, series_key: series_key, value: 1.0, recorded_at: recorded_at)
  end

  describe ".prunable scope" do
    it "includes samples older than the retention window" do
      old = sample(recorded_at: (described_class.retention_window + 1.minute).ago)
      fresh = sample(recorded_at: 1.minute.ago)

      expect(described_class.prunable).to include(old)
      expect(described_class.prunable).not_to include(fresh)
    end

    it "returns none when retention is set to 0 (infinite)" do
      AppSetting.current.update!(metrics_dashboard_sample_retention_days: 0)
      old = sample(recorded_at: 10.years.ago)

      expect(described_class.prunable).to be_empty
      expect(described_class.exists?(old.id)).to be true
    end
  end

  describe ".retention_window" do
    it "defaults to 30 days" do
      expect(described_class.retention_window).to eq(30.days)
    end
  end
end
