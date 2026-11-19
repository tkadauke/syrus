require "rails_helper"

RSpec.describe LocalBackups::Replication do
  it "keeps one record per backup and destination identity" do
    backup = LocalBackups::Backup.create!(
      uuid: SecureRandom.uuid, state: "completed", artifact_relative_path: "sealed",
      manifest_version: "1.0"
    )
    described_class.create!(backup:, destination_identity: "example.destination", state: "uploaded")

    duplicate = described_class.new(backup:, destination_identity: "example.destination", state: "uploaded")
    expect(duplicate).not_to be_valid
  end

  it "fingerprints key material without retaining it" do
    fingerprint = LocalBackups::EncryptionFingerprint.for("do-not-store")
    expect(fingerprint).to start_with("sha256:")
    expect(fingerprint).not_to include("do-not-store")
  end
end
