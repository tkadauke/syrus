require "rails_helper"

RSpec.describe LocalBackups::InventoryScanner do
  def data(id:, version: 1)
    {
      manifest_version: version, backup_id: id, installation_id: "installation", application_version: "1.2.3",
      completed_at: "2026-11-19T00:00:00Z", validated_at: "2026-11-19T00:01:00Z",
      database: { adapter: "sqlite3" }, storage: { logical_bytes: 10, stored_bytes: 8, blob_count: 1 },
      encryption_fingerprints: { primary: "sha256:#{'1' * 64}" }, artifact: { checksum_algorithm: "sha256", checksum: "b" * 64 },
      validation: { result: "valid" }
    }
  end

  it "reconstructs inventory from sealed manifests after database loss and ignores invalid artifacts" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      valid = root.join("syrus-backup-v1-valid").tap(&:mkpath)
      invalid = root.join("syrus-backup-v1-newer").tap(&:mkpath)
      LocalBackups::Manifest.new(data(id: "123e4567-e89b-42d3-a456-426614174000")).write_once(valid.join("manifest.json"))
      invalid.join("manifest.json").write(JSON.generate(data(id: "123e4567-e89b-42d3-a456-426614174001", version: 2)))

      LocalBackups::Backup.delete_all
      result = described_class.new(root: LocalBackups::StorageRoot.new(root)).call

      expect(result.discovered.map(&:uuid)).to eq([ "123e4567-e89b-42d3-a456-426614174000" ])
      expect(LocalBackups::Backup.first).to have_attributes(state: "completed", artifact_path: "syrus-backup-v1-valid", verification_state: "valid")
      expect(result.invalid).to contain_exactly(include(path: "syrus-backup-v1-newer", error: /unsupported manifest version/))
    end
  end

  it "atomically updates an already discovered backup" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      bundle = root.join("syrus-backup-v1-valid").tap(&:mkpath)
      id = "123e4567-e89b-42d3-a456-426614174000"
      LocalBackups::Manifest.new(data(id:)).write_once(bundle.join("manifest.json"))
      existing = LocalBackups::Backup.create!(
        uuid: id, state: "completed", artifact_path: "stale", manifest_version: 1,
        logical_bytes: 1, stored_bytes: 1, blob_count: 0, verification_state: "unverified", encryption_fingerprints: {}
      )

      result = described_class.new(root: LocalBackups::StorageRoot.new(root)).call

      expect(result.invalid).to be_empty
      expect(result.discovered).to contain_exactly(have_attributes(id: existing.id, artifact_path: "syrus-backup-v1-valid", verification_state: "valid"))
      expect(LocalBackups::Backup.where(uuid: id).count).to eq(1)
    end
  end

  it "uses the concurrently inserted row when another scanner wins creation" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      bundle = root.join("syrus-backup-v1-valid").tap(&:mkpath)
      id = "123e4567-e89b-42d3-a456-426614174000"
      LocalBackups::Manifest.new(data(id:)).write_once(bundle.join("manifest.json"))
      winner = LocalBackups::Backup.create!(
        uuid: id, state: "completed", artifact_path: "stale", manifest_version: 1,
        logical_bytes: 1, stored_bytes: 1, blob_count: 0, verification_state: "unverified", encryption_fingerprints: {}
      )
      allow(LocalBackups::Backup).to receive(:find_by).with(uuid: id).and_return(nil, winner)
      allow(LocalBackups::Backup).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

      result = described_class.new(root: LocalBackups::StorageRoot.new(root)).call

      expect(result.invalid).to be_empty
      expect(result.discovered).to contain_exactly(winner)
      expect(winner.reload).to have_attributes(artifact_path: "syrus-backup-v1-valid", verification_state: "valid")
    end
  end
end
