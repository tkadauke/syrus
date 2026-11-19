require "rails_helper"

RSpec.describe LocalBackups::ArtifactSource do
  let(:backup) do
    LocalBackups::Backup.create!(
      uuid: "123e4567-e89b-42d3-a456-426614174000", state: "completed", artifact_path: "syrus-backup-v1-example",
      manifest_version: 1, logical_bytes: 6, stored_bytes: 6, blob_count: 0, checksum_algorithm: "sha256",
      checksum: "d" * 64, verification_state: "valid", encryption_fingerprints: {}, completed_at: 1.hour.ago
    )
  end

  it "exposes bounded artifact reads without exposing a filesystem path" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      artifact_dir = root.join("syrus-backup-v1-example").tap(&:mkpath)
      artifact_dir.join("manifest.json").write("sealed")
      old_root = ENV["SYRUS_BACKUP_ROOT"]
      old_data = ENV["SYRUS_DATA_ROOT"]
      ENV["SYRUS_BACKUP_ROOT"] = root.to_s
      ENV["SYRUS_DATA_ROOT"] = nil
      begin
        artifact = described_class.open(backup.uuid)

        expect(artifact.entries).to eq([ "manifest.json" ])
        expect(artifact.open("manifest.json", &:read)).to eq("sealed")
        expect(artifact).not_to respond_to(:path)
        expect { artifact.open("../outside") }.to raise_error(LocalBackups::StorageRoot::Error)
      ensure
        ENV["SYRUS_BACKUP_ROOT"] = old_root
        ENV["SYRUS_DATA_ROOT"] = old_data
      end
    end
  end

  it "lists and describes completed backups" do
    pending = LocalBackups::Backup.create!(
      uuid: "123e4567-e89b-42d3-a456-426614174001", state: "pending", artifact_path: "pending",
      manifest_version: 1, logical_bytes: 0, stored_bytes: 0, blob_count: 0,
      verification_state: "unverified", encryption_fingerprints: {}
    )

    expect(described_class.list).to contain_exactly(backup)
    expect(described_class.describe(backup.uuid)).to eq(backup)
    expect(described_class.list).not_to include(pending)
  end

  it "returns checksum metadata" do
    expect(described_class.checksum(backup.uuid)).to eq("checksum_algorithm" => "sha256", "checksum" => "d" * 64)
  end

  it "pins and releases a backup for an owner" do
    described_class.pin(backup.uuid, owner: "destination:archive")
    expect(backup.reload).to be_pinned

    described_class.release_pin(backup.uuid, owner: "destination:archive")
    expect(backup.reload).not_to be_pinned
  end

  it "creates and updates one replication per destination" do
    uploaded_at = 2.minutes.ago
    replication = described_class.record_replication(
      backup.uuid,
      destination: "archive",
      result: { state: "uploaded", remote_reference: "opaque-1", uploaded_at:, ignored: "value" }
    )

    expect(replication).to have_attributes(destination_key: "archive", state: "uploaded", remote_reference: "opaque-1")
    described_class.record_replication(
      backup.uuid,
      destination: "archive",
      result: { state: "verified", remote_reference: "opaque-1", remote_checksum: "e" * 64, verified_at: Time.current }
    )

    expect(backup.replications.reload).to contain_exactly(
      have_attributes(id: replication.id, state: "verified", remote_checksum: "e" * 64)
    )
  end
end
