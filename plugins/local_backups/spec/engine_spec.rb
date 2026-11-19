require "rails_helper"

RSpec.describe "Local Backups plugin" do
  it "is bundled but disabled by default and declares completed-backup events" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "local_backups" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.events.keys).to include("local_backups.backup.completed", "local_backups.backup.validated")
  end

  it "reconstructs inventory when its enabled effects are installed" do
    scanner = instance_double(LocalBackups::InventoryScanner, call: nil)
    allow(LocalBackups::InventoryScanner).to receive(:new).and_return(scanner)

    PluginRecord.find_or_create_by!(name: "local_backups").update!(enabled: true)
    Syrus::Installer.sync!

    expect(scanner).to have_received(:call)
  ensure
    PluginRecord.find_by(name: "local_backups")&.update!(enabled: false)
    Syrus::Installer.sync!
  end
end
