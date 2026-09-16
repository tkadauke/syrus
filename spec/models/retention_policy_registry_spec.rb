require "rails_helper"

RSpec.describe RetentionPolicyRegistry do
  it "resolves every declared model to a real, loadable class" do
    described_class.definitions.each do |definition|
      expect(definition.model_class).to be_a(Class)
    end
  end

  it "matches current AppSetting defaults for every setting_key" do
    setting = AppSetting.new

    described_class.definitions.each do |definition|
      expect(setting.public_send(definition.setting_key)).to eq(definition.default_value)
    end
  end

  it "fetches a definition by key" do
    definition = described_class.fetch(:run_diagnostic)

    expect(definition.model).to eq("RunDiagnostic")
    expect(definition.setting_key).to eq(:run_diagnostic_retention_days)
  end

  it "raises for an unknown key" do
    expect { described_class.fetch(:nonexistent) }.to raise_error(KeyError)
  end

  it "keeps unit-appropriate setting_key suffixes" do
    described_class.definitions.each do |definition|
      suffix = definition.unit == :hours ? "_retention_hours" : "_retention_days"
      expect(definition.setting_key.to_s).to end_with(suffix)
    end
  end

  it "exposes json metadata" do
    definition = described_class.fetch(:operational_log_event)

    expect(definition.as_json).to include(
      key: "operational_log_event",
      model: "OperationalLogEvent",
      unit: "hours",
      default_value: 6,
      job_class: "PruneOperationalLogsJob"
    )
  end

  it "converts to an admin-editable AppSettingRegistry definition" do
    app_setting_definition = described_class.fetch(:run_diagnostic).as_app_setting_definition

    expect(app_setting_definition.key).to eq(:run_diagnostic_retention_days)
    expect(app_setting_definition.type).to eq(:integer)
    expect(app_setting_definition.admin_editable).to be true
    expect(app_setting_definition.min).to eq(0)
  end
end
