require "rails_helper"
require Rails.root.join("db/migrate/20261026180357_reduce_metrics_dashboard_sample_retention")
require Rails.root.join("db/migrate/20261028143228_create_retention_policy_settings")

RSpec.describe ReduceMetricsDashboardSampleRetention, :ci_only do
  let(:migration) { described_class.new }

  around do |example|
    current_migration = CreateRetentionPolicySettings.new
    current_migration.migrate(:down)
    ActiveRecord::Base.connection.schema_cache.clear!
    AppSetting.reset_column_information
    example.run
  ensure
    current_migration.migrate(:up) unless ActiveRecord::Base.connection.table_exists?(:retention_policy_settings)
    ActiveRecord::Base.connection.schema_cache.clear!
    AppSetting.reset_column_information
  end

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
