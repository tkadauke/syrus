require "rails_helper"

# NY21 (decided A): retention never deletes a backup that has an uploading
# replication, and an upload whose worker died stays "uploading" until the
# same destination pins again. If that destination is gone, the backup was
# protected forever. The sweep releases only an abandoned upload: its lease
# expired and no enabled, configured destination claims its identity.
RSpec.describe LocalBackups::AbandonedReplicationSweep do
  let(:now) { Time.zone.parse("2026-11-23 12:00:00") }

  def destination(identity, configured: true)
    Class.new do
      include Syrus::Plugin::BackupDestination
      define_singleton_method(:identity) { identity }
      define_singleton_method(:configured?) { configured }
    end
  end

  def uploading(identity, lease_expires_at:)
    uuid = SecureRandom.uuid
    backup = LocalBackups::Backup.create!(uuid:, state: "completed", reason: "scheduled", artifact_relative_path: uuid,
      manifest_version: "1", completed_at: now - 1.day, validated_at: now - 1.day, verification_state: "valid", stored_bytes: 10)
    backup.replications.create!(destination_identity: identity, state: "uploading", lease_token: SecureRandom.uuid,
      lease_expires_at:)
  end

  def with_destinations(*destinations)
    allow(Syrus::Host::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::Host::PluginRegistry).to receive(:providers_for).with(:backup_destination).and_return(destinations)
  end

  it "fails an expired upload whose destination is no longer enabled" do
    with_destinations(destination("s3_backup_destination:v1"))
    gone = uploading("retired_destination:v1", lease_expires_at: now - 1.hour)

    expect(described_class.new.call(now:)).to eq([ gone.id ])

    expect(gone.reload).to have_attributes(state: "failed", lease_token: nil, lease_expires_at: nil)
    expect(gone.failure_summary).to include("destination is no longer configured")
  end

  it "fails an expired upload whose destination is enabled but no longer configured" do
    with_destinations(destination("s3_backup_destination:v1", configured: false))
    unconfigured = uploading("s3_backup_destination:v1", lease_expires_at: now - 1.hour)

    described_class.new.call(now:)

    expect(unconfigured.reload.state).to eq("failed")
  end

  it "keeps an expired upload whose destination is still configured, for it to pin again" do
    with_destinations(destination("s3_backup_destination:v1"))
    live = uploading("s3_backup_destination:v1", lease_expires_at: now - 1.hour)

    expect(described_class.new.call(now:)).to eq([])
    expect(live.reload.state).to eq("uploading")
  end

  it "keeps an upload whose lease is still active, even for a destination that is gone" do
    with_destinations
    active = uploading("retired_destination:v1", lease_expires_at: now + 1.hour)

    described_class.new.call(now:)

    expect(active.reload.state).to eq("uploading")
  end

  it "releases nothing while an enabled destination does not say which identity it owns" do
    anonymous = Class.new { include Syrus::Plugin::BackupDestination }
    with_destinations(anonymous)
    gone = uploading("retired_destination:v1", lease_expires_at: now - 1.hour)

    expect(described_class.new.call(now:)).to eq([])
    expect(gone.reload.state).to eq("uploading")
  end

  it "runs before retention in the maintenance job, so the released backup can be reclaimed" do
    sweep = instance_double(described_class, call: [])
    allow(described_class).to receive(:new).and_return(sweep)
    allow(LocalBackups::PartialCleanup).to receive(:new).and_return(instance_double(LocalBackups::PartialCleanup, call: nil))
    retention = instance_double(LocalBackups::Retention)
    allow(LocalBackups::Retention).to receive(:new).and_return(retention)
    allow(retention).to receive(:call) { expect(sweep).to have_received(:call) }

    LocalBackups::MaintenanceJob.perform_now

    expect(retention).to have_received(:call)
  end
end
