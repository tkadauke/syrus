require "rails_helper"
RSpec.describe "Local backup jobs", type: :job do
  it "creates then applies retention" do
    backup = instance_double(LocalBackups::Backup, uuid: "backup-uuid", stored_bytes: 12)
    allow(LocalBackups::Creator).to receive(:new).and_return(instance_double(LocalBackups::Creator, call: backup))
    retention = instance_double(LocalBackups::Retention, call: nil)
    allow(LocalBackups::Retention).to receive(:new).and_return(retention)
    LocalBackups::CreateJob.perform_now(reason: "manual")
    expect(retention).to have_received(:call)
  end
  it "runs cleanup and retention maintenance" do
    cleanup = instance_double(LocalBackups::PartialCleanup, call: nil)
    retention = instance_double(LocalBackups::Retention, call: nil)
    allow(LocalBackups::PartialCleanup).to receive(:new).and_return(cleanup)
    allow(LocalBackups::Retention).to receive(:new).and_return(retention)
    LocalBackups::MaintenanceJob.perform_now
    expect(cleanup).to have_received(:call)
    expect(retention).to have_received(:call)
  end
  it "delegates deletion to retention" do
    backup = instance_double(LocalBackups::Backup)
    retention = instance_double(LocalBackups::Retention, delete!: nil)
    allow(LocalBackups::Backup).to receive(:find).with(42).and_return(backup)
    allow(LocalBackups::Retention).to receive(:new).and_return(retention)
    LocalBackups::DeleteJob.perform_now(42)
    expect(retention).to have_received(:delete!).with(backup)
  end
end
