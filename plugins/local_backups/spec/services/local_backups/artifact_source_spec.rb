require "rails_helper"

RSpec.describe LocalBackups::ArtifactSource do
  let!(:backup) do
    LocalBackups::Backup.create!(
      uuid: SecureRandom.uuid,
      state: "completed",
      artifact_relative_path: "sealed",
      manifest_version: "1.0",
      completed_at: Time.current,
      logical_bytes: 20,
      stored_bytes: 10,
      artifact_checksum: "a" * 64,
      checksum_algorithm: "sha256"
    )
  end

  it "describes completed artifacts without exposing filesystem paths" do
    expect(described_class.list(context: nil)).to contain_exactly(
      id: backup.uuid,
      completed_at: backup.completed_at,
      checksum: { algorithm: "sha256", value: "a" * 64 },
      logical_bytes: 20,
      stored_bytes: 10
    )
  end

  it "does not substitute the manifest for a streamable backup artifact" do
    expect { described_class.open(backup.uuid, context: nil) }
      .to raise_error(described_class::UnsupportedOperation, /sealed archives/)
  end
end
