require "rails_helper"

RSpec.describe MetricsDashboard::PruneJob do
  def sample(recorded_at:, series_key: SecureRandom.hex(4))
    MetricsDashboard::Sample.create!(metric: "m", series_key: series_key, value: 1.0, recorded_at: recorded_at)
  end

  it "deletes samples older than the retention window" do
    old = sample(recorded_at: (MetricsDashboard::Sample.retention_window + 1.minute).ago)
    fresh = sample(recorded_at: 1.minute.ago)

    described_class.perform_now

    expect(MetricsDashboard::Sample.exists?(old.id)).to be false
    expect(MetricsDashboard::Sample.exists?(fresh.id)).to be true
  end

  it "is a no-op when retention is set to 0 (infinite)" do
    AppSetting.current.update!(metrics_dashboard_sample_retention_days: 0)
    old = sample(recorded_at: 10.years.ago)

    described_class.perform_now

    expect(MetricsDashboard::Sample.exists?(old.id)).to be true
  end
end
