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
end
