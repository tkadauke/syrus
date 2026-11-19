require "rails_helper"

RSpec.describe LocalBackups::Creator do
  self.use_transactional_tests = false

  let(:capacity) do
    instance_double(LocalBackups::CapacityAdmission, admit!: true)
  end

  around do |example|
    LocalBackups::ObjectHold.delete_all
    LocalBackups::Backup.delete_all
    ActiveStorage::Attachment.delete_all
    ActiveStorage::Blob.delete_all
    Dir.mktmpdir do |directory|
      @root = LocalBackups::StorageRoot.new(configured: directory, data_root: nil)
      begin
        example.run
      ensure
        Pathname.new(directory).find { |path| File.chmod(path.directory? ? 0o700 : 0o600, path) }
      end
    end
  ensure
    LocalBackups::ObjectHold.delete_all
    LocalBackups::Backup.delete_all
    ActiveStorage::Attachment.delete_all
    ActiveStorage::Blob.delete_all
    FileUtils.rm_rf(ActiveStorage::Blob.service.root)
  end

  it "streams and seals every selected Disk blob into an immutable artifact" do
    blob = create_blob("recover me")

    backup = described_class.new(root: @root, capacity:).call
    artifact = @root.path.join(backup.artifact_relative_path)
    manifest = LocalBackups::Manifest.read(artifact.join("manifest.json")).attributes
    entry = manifest.dig("active_storage", "blobs").sole

    expect(backup.state).to eq("completed")
    expect(artifact.join(entry.fetch("relative_path")).binread).to eq("recover me")
    expect(artifact.stat.mode & 0o777).to eq(0o500)
    expect(artifact.join("manifest.json").stat.mode & 0o777).to eq(0o400)
    expect(entry.fetch("id")).to eq(blob.id)
  end

  it "fails closed when a selected blob is corrupt" do
    blob = create_blob("expected")
    Pathname.new(ActiveStorage::Blob.service.send(:path_for, blob.key)).binwrite("corrupt")

    expect { described_class.new(root: @root, capacity:).call }
      .to raise_error(LocalBackups::DiskBlobExporter::InvalidBlob, /truncated|checksum/)

    expect(LocalBackups::Backup.last.state).to eq("failed")
    expect(@root.path.glob("syrus-backup-v1-*")).to be_empty
  end

  it "preserves prior sealed artifacts across crashes in every construction phase" do
    prior = @root.path.join("syrus-backup-v1-prior").tap(&:mkdir)
    prior.join("marker").write("valid")
    create_blob("selected")

    %i[partial_created database_snapshotted objects_held objects_exported ready_to_seal].each do |crash_phase|
      hook = ->(phase) { raise "simulated crash at #{phase}" if phase == crash_phase }

      expect { described_class.new(root: @root, capacity:, phase_hook: hook).call }
        .to raise_error("simulated crash at #{crash_phase}")

      expect(prior.join("marker").read).to eq("valid")
      expect(LocalBackups::Backup.last.state).to eq("failed")
      expect(LocalBackups::ObjectHold.count).to eq(0)
    end

    expect(@root.path.glob(".*.partial").size).to eq(5)
  end

  it "rejects a second installation-wide creator while the lease is held" do
    lease = LocalBackups::Lease.new(root: @root)

    lease.synchronize do
      expect { described_class.new(root: @root, capacity:).call }
        .to raise_error(LocalBackups::Lease::Busy)
    end
  end

  it "blocks purge while a captured object is held" do
    ActiveStorage::Blob.prepend(LocalBackups::PurgeGuard) unless ActiveStorage::Blob < LocalBackups::PurgeGuard
    blob = create_blob("held")
    backup = LocalBackups::Backup.create!(
      uuid: SecureRandom.uuid, state: "exporting_objects", artifact_relative_path: ".partial",
      manifest_version: "1.0", logical_bytes: 0, stored_bytes: 0, blob_count: 0
    )
    backup.object_holds.create!(active_storage_blob_id: blob.id, storage_key: blob.key)

    expect { blob.purge }.to raise_error(LocalBackups::PurgeGuard::ObjectHeld)
    expect(ActiveStorage::Blob).to exist(blob.id)
  end

  it "does not write a partial artifact when capacity admission fails" do
    denied = instance_double(LocalBackups::CapacityAdmission)
    allow(denied).to receive(:admit!).and_raise(
      LocalBackups::CapacityAdmission::InsufficientSpace.new(required_bytes: 20, available_bytes: 10)
    )

    expect { described_class.new(root: @root, capacity: denied).call }
      .to raise_error(LocalBackups::CapacityAdmission::InsufficientSpace)

    expect(@root.path.glob(".*.partial")).to be_empty
  end

  def create_blob(content)
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(content), filename: "backup.txt", content_type: "text/plain"
    )
  end
end
