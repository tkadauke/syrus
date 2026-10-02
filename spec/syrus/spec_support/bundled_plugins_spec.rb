require "rails_helper"

RSpec.describe Syrus::SpecSupport::BundledPlugins do
  describe ".restore_test_provider_records" do
    it "enables the test provider plugin records and clears the registry cache" do
      described_class::TEST_PROVIDER_PLUGIN_NAMES.each do |plugin_name|
        record = PluginRecord.find_or_create_by!(name: plugin_name)
        updates = { enabled: false }
        updates[:disableable] = true if record.has_attribute?(:disableable)
        record.update_columns(updates)
      end

      expect(Syrus::PluginRegistry).to receive(:clear_plugin_record_cache!).at_least(:once).and_call_original

      described_class.restore_test_provider_records

      described_class::TEST_PROVIDER_PLUGIN_NAMES.each do |plugin_name|
        expect(PluginRecord.find_by!(name: plugin_name)).to be_enabled
      end
    end

    it "fails open when plugin registry materialization cannot read plugin_records" do
      allow(Syrus::PluginRegistry).to receive(:all_plugins).and_raise(
        ActiveRecord::StatementInvalid.new("SQLite3::SQLException: no such table: plugin_records")
      )

      expect {
        described_class.restore_test_provider_records
      }.not_to raise_error
    end

    it "fails open when provider records cannot be restored" do
      allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([])
      allow(PluginRecord).to receive(:find_or_create_by!).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect {
        described_class.restore_test_provider_records
      }.not_to raise_error
    end
  end
end
