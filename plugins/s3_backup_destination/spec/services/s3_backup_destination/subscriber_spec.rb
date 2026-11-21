require "rails_helper"

RSpec.describe S3BackupDestination::Subscriber do
  let(:source) { class_double(LocalBackups::ArtifactSource) }
  let(:event) { Syrus::DomainEvent.new(name: "local_backups.backup.completed", payload: { backup_uuid: "backup-1" }) }
  let(:lease_token) { "attempt-token" }
  let(:lease_context) { { lease_token: } }

  before do
    allow(Syrus::Host::PluginRegistry).to receive(:providers_for).with(:backup_artifact_source).and_return([source])
    allow(source).to receive(:pin).and_return(lease_token)
    allow(source).to receive(:describe).and_return(id: "backup-1", checksum: { value: "source" })
    allow(source).to receive(:open).and_return(StringIO.new("archive"))
    allow(source).to receive(:record_replication)
    allow(source).to receive(:release_pin)
    allow(S3BackupDestination::Destination).to receive(:upload)
  end

  it "does not repeat work for an already verified destination" do
    allow(source).to receive(:pin).and_return(false)

    described_class.replicate(event)

    expect(source).not_to have_received(:describe)
    expect(S3BackupDestination::Destination).not_to have_received(:upload)
    expect(source).not_to have_received(:record_replication)
    expect(source).not_to have_received(:release_pin)
  end

  it "records verified state without exposing source paths" do
    allow(S3BackupDestination::Destination).to receive(:upload).and_return(remote_reference: "opaque", checksum: "remote")
    allow(S3BackupDestination::Destination).to receive(:verify).and_return(verified: true, checksum: "remote")

    described_class.replicate(event)

    expect(source).to have_received(:record_replication).with(
      "backup-1", destination: S3BackupDestination::Destination::IDENTITY, context: lease_context,
      result: hash_including(state: "verified", remote_reference: "opaque", remote_checksum: "remote")
    )
    expect(source).to have_received(:release_pin).with(
      "backup-1", owner: S3BackupDestination::Destination::IDENTITY, context: lease_context
    )
  end

  it "contains destination failure and records a redacted failure" do
    allow(S3BackupDestination::Destination).to receive(:upload).and_raise("https://secret.example/object failed")

    expect { described_class.replicate(event) }.not_to raise_error
    expect(source).to have_received(:record_replication).with(
      "backup-1", destination: S3BackupDestination::Destination::IDENTITY, context: lease_context,
      result: hash_including(state: "failed", failure_summary: satisfy { |value| !value.include?("secret.example") })
    )
  end
end
