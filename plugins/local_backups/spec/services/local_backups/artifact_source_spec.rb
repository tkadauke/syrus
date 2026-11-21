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
    described_class.pin(backup.uuid, owner: "s3:v1", context: nil)
    expect(backup.replications.find_by!(destination_identity: "s3:v1").state).to eq("uploading")

    2.times do
      described_class.record_replication(backup.uuid, destination: "s3:v1", context: nil, result: {
        state: "failed", failure_summary: "request to https://secret.example/object failed"
      })
    end
    replication = backup.replications.find_by!(destination_identity: "s3:v1")
    expect(replication.state).to eq("failed")
    expect(replication.failure_summary).to eq("request to [REDACTED_URL] failed")
  end
end
