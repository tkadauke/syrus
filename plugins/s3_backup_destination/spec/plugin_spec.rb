require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe "S3 backup destination plugin package" do
  let(:plugin) { syrus_plugin(Pathname.new(__dir__).join("..")) }

  before do
    PluginRecord.find_by!(name: "s3_backup_destination").update!(enabled: true)
  end

  it "is a healthy compatible package with public-only host usage" do
    expect(plugin).to be_plugin_loaded
    expect(plugin).to be_plugin_healthy
    expect(plugin).to have_valid_plugin_manifest
    expect(plugin).to satisfy_requires_syrus
    expect(plugin).to have_clean_plugin_host_surface
  end

  it "registers the versioned destination and isolated event subscriber" do
    expect(plugin).to register_plugin_provider(:backup_destination).matching(S3BackupDestination::Destination)
    expect(plugin).to register_plugin_provider(:domain_subscriber).matching(S3BackupDestination::Subscriber)
    expect(S3BackupDestination::Destination).to be_compatible_version("1.0")
  end
end
