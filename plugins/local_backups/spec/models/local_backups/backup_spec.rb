require "rails_helper"

RSpec.describe LocalBackups::Backup do
  it "owns destination-specific replication inventory without storing credentials" do
    backup = described_class.create!(
      uuid: "123e4567-e89b-42d3-a456-426614174000", state: "completed", artifact_path: "bundle",
      manifest_version: 1, logical_bytes: 1, stored_bytes: 1, blob_count: 0,
      verification_state: "valid", encryption_fingerprints: { "primary" => "sha256:#{'1' * 64}" }
    )
    backup.replications.create!(destination_key: "example_offsite", state: "verified", remote_reference: "opaque:123")

    expect(backup.replications.first).to have_attributes(destination_key: "example_offsite", remote_reference: "opaque:123")
    expect(LocalBackups::Replication.column_names).not_to include("credentials", "secret", "access_token")
    expect { backup.replications.create!(destination_key: "example_offsite", state: "pending") }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
