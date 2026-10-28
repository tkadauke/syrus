require "rails_helper"

RSpec.describe MetricsDashboard::RetentionPolicy, requires_plugin: "metrics_dashboard" do
  before do
    PluginRecord.find_or_create_by!(name: "metrics_dashboard").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

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
    expect(definition.default_value).to eq(7)
    expect(definition.unit).to eq(:days)
    expect(definition.job_class).to eq("MetricsDashboard::PruneJob")
    expect(definition.description).to include("longest selectable window (7 days)")
  end

  it "does not become a core definition" do
    expect(RetentionPolicyRegistry::CORE_DEFINITIONS.map(&:key)).not_to include(:metrics_dashboard_sample)
  end

  it "stores its effective value in canonical seconds" do
    definition = described_class.retention_definitions.fetch(0)

    expect(definition.default_seconds).to eq(7.days.to_i)
    expect(definition.setting.archive_before_delete).to be_nil
  end
end
