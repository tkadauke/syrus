require "rails_helper"

RSpec.describe LocalBackups::ArtifactSource do
  around do |example|
    Dir.mktmpdir do |directory|
      @backup_root = Pathname.new(directory)
      previous = ENV["SYRUS_BACKUP_ROOT"]
      ENV["SYRUS_BACKUP_ROOT"] = directory
      example.run
    ensure
      previous.nil? ? ENV.delete("SYRUS_BACKUP_ROOT") : ENV["SYRUS_BACKUP_ROOT"] = previous
    end
  end

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

  it "streams a sealed archive without exposing its path" do
    sealed = @backup_root.join("sealed")
    sealed.mkdir
    sealed.join("manifest.json").write("sealed bundle")

    io = described_class.open(backup.uuid, context: nil)
    expect(io.read).to include("sealed bundle")
    expect(io).to be_a(Tempfile)
  ensure
    io&.close!
  end

  it "records destination-scoped pins and redacted results idempotently" do
    2.times do
      lease_token = described_class.pin(backup.uuid, owner: "s3:v1", context: nil)
      expect(backup.replications.find_by!(destination_identity: "s3:v1").state).to eq("uploading")
      described_class.record_replication(backup.uuid, destination: "s3:v1", context: { lease_token: }, result: {
        state: "failed", failure_summary: "request to https://secret.example/object failed"
      })
    end
    replication = backup.replications.find_by!(destination_identity: "s3:v1")
    expect(replication.state).to eq("failed")
    expect(replication.failure_summary).to eq("request to [REDACTED_URL] failed")
  end

  it "preserves verified evidence when a completion event is delivered again" do
    lease_token = described_class.pin(backup.uuid, owner: "s3:v1", context: nil)
    described_class.record_replication(backup.uuid, destination: "s3:v1", context: { lease_token: }, result: {
      state: "verified", remote_reference: "opaque-reference", remote_checksum: "b" * 64,
      uploaded_at: 1.hour.ago, verified_at: 1.hour.ago
    })
    replication = backup.replications.find_by!(destination_identity: "s3:v1")
    created_at = replication.created_at

    expect(described_class.pin(backup.uuid, owner: "s3:v1", context: nil)).to be(false)
    described_class.record_replication(backup.uuid, destination: "s3:v1", context: { lease_token: }, result: {
      state: "failed", failure_summary: "duplicate delivery failed"
    })

    expect(replication.reload).to have_attributes(
      state: "verified", remote_reference: "opaque-reference", remote_checksum: "b" * 64,
      failure_summary: nil, created_at:
    )
  end

  it "allows only one live lease and rejects stale attempt mutations after reacquisition" do
    first_token = described_class.pin(backup.uuid, owner: "s3:v1", context: nil)

    expect(first_token).to be_present
    expect(described_class.pin(backup.uuid, owner: "s3:v1", context: nil)).to be(false)

    replication = backup.replications.find_by!(destination_identity: "s3:v1")
    replication.update!(lease_expires_at: 1.minute.ago)
    second_token = described_class.pin(backup.uuid, owner: "s3:v1", context: nil)

    expect(second_token).to be_present
    expect(second_token).not_to eq(first_token)
    expect(described_class.release_pin(
      backup.uuid, owner: "s3:v1", context: { lease_token: first_token }
    )).to be(false)
    expect(described_class.record_replication(
      backup.uuid, destination: "s3:v1", context: { lease_token: first_token },
      result: { state: "failed", failure_summary: "stale failure" }
    )).to be(false)
    expect(replication.reload).to have_attributes(state: "uploading", lease_token: second_token)

    expect(described_class.record_replication(
      backup.uuid, destination: "s3:v1", context: { lease_token: second_token },
      result: { state: "verified", remote_reference: "opaque", remote_checksum: "c" * 64 }
    )).to be(true)
    expect(replication.reload).to have_attributes(
      state: "verified", lease_token: nil, lease_expires_at: nil, failure_summary: nil
    )
  end
end
