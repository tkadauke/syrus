require "rails_helper"

RSpec.describe TestInsights::RetentionPolicy do
  it "includes the Syrus::Plugin::RetentionPolicy interface" do
    expect(described_class).to include(Syrus::Plugin::RetentionPolicy)
  end

  it "contributes exactly the test_insight_case retention definition" do
    definitions = described_class.retention_definitions

    expect(definitions.size).to eq(1)
    definition = definitions.first
    expect(definition.key).to eq(:test_insight_case)
    expect(definition.model).to eq("TestInsights::TestCase")
    expect(definition.model_class).to eq(TestInsights::TestCase)
    expect(definition.table_name).to eq("test_insight_cases")
    expect(definition.age_column).to eq(:created_at)
    expect(definition.scope_name).to eq(:prunable)
    expect(definition.setting_key).to eq(:test_insight_case_retention_days)
    expect(definition.default_value).to eq(90)
    expect(definition.unit).to eq(:days)
    expect(definition.executor_class).to eq("TestInsights::RetentionExecutor")
  end

  it "is merged into the registry without becoming a core definition" do
    expect(RetentionPolicyRegistry.definitions.map(&:key)).to include(:test_insight_case)
    expect(RetentionPolicyRegistry::CORE_DEFINITIONS.map(&:key)).not_to include(:test_insight_case)
    expect(RetentionPolicyRegistry.fetch(:test_insight_case).model_class).to eq(TestInsights::TestCase)
  end

  it "stores its effective value in canonical seconds" do
    definition = RetentionPolicyRegistry.fetch(:test_insight_case)

    expect(definition.default_seconds).to eq(90.days.to_i)
    expect(definition.setting.archive_before_delete).to be_nil
  end
end
