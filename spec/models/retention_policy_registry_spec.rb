require "rails_helper"

RSpec.describe RetentionPolicyRegistry do
  # Scoped to CORE_DEFINITIONS, not the merged .definitions: a core spec
  # must not depend on which plugins happen to be installed, or a bundled
  # plugin that contributes a :retention_policy provider (see
  # plugins/metrics_dashboard) becomes undeletable in practice. See
  # config/syrus_docs/plugins.md and CLAUDE.md's plugin-boundary rule.
  it "resolves every core-declared model to a real, loadable class" do
    described_class::CORE_DEFINITIONS.each do |definition|
      expect(definition.model_class).to be_a(Class)
    end
  end

  it "matches current AppSetting defaults for every core setting_key" do
    setting = AppSetting.new

    described_class::CORE_DEFINITIONS.each do |definition|
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

  it "keeps unit-appropriate setting_key suffixes for core definitions" do
    described_class::CORE_DEFINITIONS.each do |definition|
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

  it "computes the archive_setting_key convention for every core definition" do
    described_class::CORE_DEFINITIONS.each do |definition|
      expect(definition.archive_setting_key).to eq(:"#{definition.key}_archive_before_delete")
    end
  end

  it "marks archivable: true only for tables where archiving before delete is meaningful" do
    archivable_keys = described_class::CORE_DEFINITIONS.select(&:archivable).map(&:key)

    expect(archivable_keys).to contain_exactly(
      :run_diagnostic,
      :work_engine_reconciler_activity,
      :provider_session,
      :run_health_snapshot,
      :main_branch_health_check
    )
  end

  it "leaves the lookback-only entry (no scope_name/job_class) non-archivable" do
    definition = described_class.fetch(:workflow_step_resource_profile_input)

    expect(definition.archivable).to be false
    expect(definition.as_archive_app_setting_definition).to be_nil
  end

  it "converts an archivable definition to an admin-editable boolean AppSettingRegistry definition" do
    app_setting_definition = described_class.fetch(:provider_session).as_archive_app_setting_definition

    expect(app_setting_definition.key).to eq(:provider_session_archive_before_delete)
    expect(app_setting_definition.type).to eq(:boolean)
    expect(app_setting_definition.default).to eq(false)
    expect(app_setting_definition.admin_editable).to be true
  end

  it "returns nil as_archive_app_setting_definition for a non-archivable definition" do
    expect(described_class.fetch(:notification).as_archive_app_setting_definition).to be_nil
  end

  it "collects every archivable definition's setting into .archive_app_setting_definitions" do
    keys = described_class.archive_app_setting_definitions.map(&:key)

    expect(keys).to include(:provider_session_archive_before_delete, :run_diagnostic_archive_before_delete)
    expect(keys).not_to include(:notification_archive_before_delete)
  end

  describe "plugin-contributed definitions" do
    let(:fake_provider) do
      Class.new do
        include Syrus::Plugin::RetentionPolicy

        def self.retention_definitions
          [
            RetentionPolicyRegistry::Definition.new(
              key: :fake_plugin_table,
              model: "FakePluginModel",
              table_name: "fake_plugin_rows",
              age_column: :created_at,
              scope_name: :prunable,
              setting_key: :fake_plugin_table_retention_days,
              default_value: 5,
              unit: :days,
              job_class: "FakePluginPruneJob",
              description: "A fake plugin-owned table, for testing the merge.",
              category: "Plugins",
              archivable: false
            )
          ]
        end
      end
    end

    before do
      Syrus::PluginRegistry.register(
        name: "fake-retention-plugin",
        version: "1.0.0",
        provides: { retention_policy: fake_provider }
      )
    end

    it "merges a plugin's contributed definitions into .definitions" do
      expect(described_class.definitions.map(&:key)).to include(:fake_plugin_table)
      expect(described_class::CORE_DEFINITIONS.map(&:key)).not_to include(:fake_plugin_table)
    end

    it "is fetchable once merged" do
      expect(described_class.fetch(:fake_plugin_table).model).to eq("FakePluginModel")
    end

    it "is not filtered by whether the contributing plugin is enabled" do
      PluginRecord.find_or_create_by!(name: "fake-retention-plugin") { |r| r.enabled = false }

      expect(described_class.definitions.map(&:key)).to include(:fake_plugin_table)
    end
  end
end
