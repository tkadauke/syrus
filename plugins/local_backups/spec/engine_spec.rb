require "rails_helper"

RSpec.describe "Local Backups plugin" do
  it "is bundled but disabled by default and declares completed-backup events" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "local_backups" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.events.keys).to include("local_backups.backup.completed", "local_backups.backup.validated")
  end
end
