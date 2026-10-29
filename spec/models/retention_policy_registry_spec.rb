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

  it "keeps keys unique and every registered table, scope, setting, and executor resolvable" do
    expect(described_class.definitions.map(&:key)).to eq(described_class.definitions.map(&:key).uniq)
    expect { described_class.validate! }.not_to raise_error
  end

  it "backs stable policy settings with the required unique index" do
    index = ActiveRecord::Base.connection.indexes(:retention_policy_settings)
      .find { |candidate| candidate.columns == [ "retention_key" ] }

    expect(index.unique).to be(true)
  end

  it "provides canonical-second defaults for every core policy" do
    described_class::CORE_DEFINITIONS.each do |definition|
      expect(definition.default_seconds).to eq(definition.default_value.public_send(definition.unit).to_i)
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
      executor_class: "RetentionPolicyExecutors::OperationalLogEvent"
    )
  end

  it "keeps display units in metadata while converting persisted seconds" do
    job_logs = described_class.fetch(:job_log)
    performance_events = described_class.fetch(:performance_log_event)

    expect(job_logs.value_for(30.days.to_i)).to eq(30)
    expect(performance_events.value_for(24.hours.to_i)).to eq(24)
    expect(job_logs.value_for(nil)).to eq(0)
  end

  it "computes the archive_setting_key convention for every core definition" do
    described_class::CORE_DEFINITIONS.each do |definition|
      expect(definition.archive_setting_key).to eq(:"#{definition.key}_archive_before_delete")
    end
  end

  it "marks archivable: true only for tables where archiving before delete is meaningful" do
    archivable_keys = described_class::CORE_DEFINITIONS.select(&:archivable).map(&:key)

    expect(archivable_keys).to contain_exactly(
      :job_log,
      :run_diagnostic,
      :work_engine_reconciler_activity,
      :provider_session,
      :run_health_snapshot,
      :main_branch_health_check
    )
  end

  it "does not treat the resource-profile query lookback as row retention" do
    expect(described_class::CORE_DEFINITIONS.map(&:key)).not_to include(:workflow_step_resource_profile_input)
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
              executor_class: nil,
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
        default_enabled: true,
        disableable: true,
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

    it "excludes a disabled plugin while leaving any persisted setting inert" do
      PluginRecord.find_or_create_by!(name: "fake-retention-plugin").update!(enabled: false)
      Syrus::PluginRegistry.clear_plugin_record_cache!
      RetentionPolicySetting.create!(retention_key: "fake_plugin_table", retention_seconds: 5.days.to_i)

      expect(described_class.definitions.map(&:key)).not_to include(:fake_plugin_table)
      expect(RetentionPolicySetting.find_by!(retention_key: "fake_plugin_table").retention_seconds).to eq(5.days.to_i)
    end

    it "isolates a broken plugin provider from core and other plugin definitions" do
      broken_provider = Class.new do
        include Syrus::Plugin::RetentionPolicy

        def self.name = "BrokenRetentionPlugin::Policy"
        def self.retention_definitions = raise("broken provider")
      end
      Syrus::PluginRegistry.register(
        name: "broken-retention-plugin",
        version: "1.0.0",
        default_enabled: true,
        disableable: true,
        provides: { retention_policy: broken_provider }
      )

      expect(Rails.logger).to receive(:error).with(/BrokenRetentionPlugin::Policy.*broken provider/)

      keys = described_class.definitions.map(&:key)

      expect(keys).to include(:notification, :fake_plugin_table)
    end
  end
end
