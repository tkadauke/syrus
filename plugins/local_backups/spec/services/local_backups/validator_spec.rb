require "rails_helper"
require_relative "../../support/resolved_tmpdir"

RSpec.describe LocalBackups::Validator do
  around do |example|
    Dir.mktmpdir do |root|
      @root = LocalBackups::StorageRoot.new(configured: root, data_root: nil)
      example.run
    end
  end

  it "validates every declared checksum and records success" do
    artifact = @root.path.join("artifact").tap(&:mkdir)
    artifact.join("payload").write("safe")
    artifact.join("checksums.sha256").write("#{Digest::SHA256.hexdigest('safe')}  payload\n")
    LocalBackups::Manifest.write(artifact, backup_id: SecureRandom.uuid, completed_at: Time.current.iso8601,
      artifact: { logical_bytes: 4, stored_bytes: 4, blob_count: 0 }, checksum: { algorithm: "sha256", value: "c" * 64 })
    backup = LocalBackups::Backup.create!(uuid: SecureRandom.uuid, state: "completed", artifact_relative_path: "artifact", manifest_version: "1")

    described_class.new(root: @root).call(backup)

    expect(backup.reload).to have_attributes(verification_state: "valid", validated_at: be_present)
  end

  it "marks a changed artifact invalid" do
    artifact = @root.path.join("artifact").tap(&:mkdir)
    artifact.join("payload").write("changed")
    artifact.join("checksums.sha256").write("#{'0' * 64}  payload\n")
    backup = LocalBackups::Backup.create!(uuid: SecureRandom.uuid, state: "completed", artifact_relative_path: "artifact", manifest_version: "1")

    expect { described_class.new(root: @root).call(backup) }.to raise_error(LocalBackups::Validator::Invalid, /mismatch/)
    expect(backup.reload.verification_state).to eq("invalid")
  end
end
