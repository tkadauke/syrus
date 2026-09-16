require "rails_helper"

RSpec.describe MetricsDashboard::RetentionPolicy do
  it "includes the Syrus::Plugin::RetentionPolicy interface" do
    expect(described_class).to include(Syrus::Plugin::RetentionPolicy)
  end

  it "contributes the metrics_dashboard_sample retention definition" do
    definitions = described_class.retention_definitions

    expect(definitions.size).to eq(1)
    definition = definitions.first
    expect(definition.key).to eq(:metrics_dashboard_sample)
    expect(definition.model).to eq("MetricsDashboard::Sample")
    expect(definition.model_class).to eq(MetricsDashboard::Sample)
    expect(definition.table_name).to eq("metrics_dashboard_samples")
    expect(definition.setting_key).to eq(:metrics_dashboard_sample_retention_days)
    expect(definition.default_value).to eq(30)
    expect(definition.unit).to eq(:days)
    expect(definition.job_class).to eq("MetricsDashboard::PruneJob")
  end

  it "is registered with core's RetentionPolicyRegistry and merged into .definitions" do
    expect(RetentionPolicyRegistry.definitions.map(&:key)).to include(:metrics_dashboard_sample)
    expect(RetentionPolicyRegistry::CORE_DEFINITIONS.map(&:key)).not_to include(:metrics_dashboard_sample)
    expect(RetentionPolicyRegistry.fetch(:metrics_dashboard_sample).model_class).to eq(MetricsDashboard::Sample)
  end

  it "is folded into AppSettingRegistry as an admin-editable setting" do
    definition = AppSettingRegistry.fetch(:metrics_dashboard_sample_retention_days)

    expect(definition.type).to eq(:integer)
    expect(definition.default).to eq(30)
    expect(definition.admin_editable).to be true
  end
end
