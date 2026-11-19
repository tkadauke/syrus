require "rails_helper"

RSpec.describe LocalBackups::ArtifactSource do
  it "exposes bounded artifact reads without exposing a filesystem path" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      artifact_dir = root.join("syrus-backup-v1-example").tap(&:mkpath)
      artifact_dir.join("manifest.json").write("sealed")
      backup = LocalBackups::Backup.create!(
        uuid: "123e4567-e89b-42d3-a456-426614174000", state: "completed", artifact_path: artifact_dir.basename.to_s,
        manifest_version: 1, logical_bytes: 6, stored_bytes: 6, blob_count: 0, checksum_algorithm: "sha256",
        checksum: "d" * 64, verification_state: "valid", encryption_fingerprints: {}
      )
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
end
