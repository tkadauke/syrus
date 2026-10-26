require "rails_helper"
require Rails.root.join("db/migrate/20261026180357_reduce_metrics_dashboard_sample_retention")

RSpec.describe ReduceMetricsDashboardSampleRetention, :ci_only do
  let(:migration) { described_class.new }

  it "replaces the known year-long setting without overriding other operator choices" do
    setting = AppSetting.current
    setting.update!(metrics_dashboard_sample_retention_days: 365)

    migration.up

    expect(setting.reload.metrics_dashboard_sample_retention_days).to eq(7)

    setting.update!(metrics_dashboard_sample_retention_days: 14)
    migration.up
    expect(setting.reload.metrics_dashboard_sample_retention_days).to eq(14)
  end
end
