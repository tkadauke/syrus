require "rails_helper"
require_relative "../../support/resolved_tmpdir"

RSpec.describe LocalBackups::InventoryScanner do
  it "reconstructs inventory from sealed manifests after rows are lost" do
    Dir.mktmpdir do |parent|
      root = Pathname.new(parent).join("backups").tap(&:mkpath)
      artifact = root.join("sealed-one").tap(&:mkpath)
      uuid = SecureRandom.uuid
      LocalBackups::Manifest.write(artifact, {
        backup_id: uuid, completed_at: Time.current.iso8601, reason: "manual",
        database: { adapter: "sqlite3" }, source: { application_version: "1.2.3" },
        artifact: { logical_bytes: 20, stored_bytes: 10, blob_count: 2 },
        checksum: { algorithm: "sha256", value: "b" * 64 },
        encryption: { key_fingerprint: LocalBackups::EncryptionFingerprint.for("secret") }
      })

      scanner = described_class.new(root: LocalBackups::StorageRoot.new(configured: root.to_s))
      expect { scanner.call }.to change(LocalBackups::Backup, :count).by(1)
      LocalBackups::Backup.delete_all
      expect { scanner.call }.to change(LocalBackups::Backup, :count).by(1)
      expect(LocalBackups::Backup.find_by!(uuid:).artifact_relative_path).to eq("sealed-one")
    end
  end
end
