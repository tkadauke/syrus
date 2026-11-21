require "rails_helper"
require_relative "../../support/resolved_tmpdir"

RSpec.describe LocalBackups::Retention do
  around do |example|
    Dir.mktmpdir do |root|
      @root = LocalBackups::StorageRoot.new(configured: root, data_root: nil)
      example.run
    end
  end

  def backup(at:, pinned: false, replicated: false)
    uuid = SecureRandom.uuid
    @root.path.join(uuid).mkdir
    record = LocalBackups::Backup.create!(uuid:, state: "completed", reason: "scheduled", artifact_relative_path: uuid,
      manifest_version: "1", completed_at: at, validated_at: at, verification_state: "valid", pinned:, stored_bytes: 10)
    record.replications.create!(destination_identity: "test", state: "verified") if replicated
    record
  end

  it "deletes oldest excess backups while protecting the newest valid and pins" do
    newest = backup(at: 1.hour.ago)
    pinned = backup(at: 2.hours.ago, pinned: true)
    old = backup(at: 3.hours.ago)

    result = described_class.new(root: @root, keep_count: 1, keep_days: 30, max_bytes: 0).call

    expect(result.deleted).to eq([old.uuid])
    expect(result.blocked).to eq([pinned.uuid])
    expect(newest.reload.state).to eq("completed")
    expect(old.reload.state).to eq("deleted")
  end

  it "requires verified replication when configured" do
    backup(at: 1.hour.ago)
    unreplicated = backup(at: 2.hours.ago)

    result = described_class.new(root: @root, keep_count: 1, keep_days: 30, max_bytes: 0, require_replication: true).call

    expect(result.blocked).to eq([unreplicated.uuid])
  end

  it "never deletes an artifact while a destination is uploading it" do
    backup(at: 1.hour.ago)
    uploading = backup(at: 2.hours.ago)
    uploading.replications.create!(destination_identity: "s3:v1", state: "uploading")

    result = described_class.new(root: @root, keep_count: 1, keep_days: 30).call

    expect(result.blocked).to include(uploading.uuid)
    expect(uploading.reload.state).to eq("completed")
    expect(@root.path.join(uploading.artifact_relative_path)).to exist
  end

  it "rechecks replication under lock after the sweep selected its candidate" do
    backup(at: 1.hour.ago)
    candidate = backup(at: 2.hours.ago, replicated: true)
    retention = described_class.new(root: @root, keep_count: 1, keep_days: 30, require_replication: true)
    allow(retention).to receive(:claim_deletions!).and_wrap_original do |original, candidate_ids|
      candidate.replications.update_all(state: "failed")
      original.call(candidate_ids)
    end

    result = retention.call

    expect(result.deleted).to be_empty
    expect(result.blocked).to include(candidate.uuid)
    expect(candidate.reload.state).to eq("completed")
    expect(@root.path.join(candidate.artifact_relative_path)).to exist
  end

  it "protects the newest valid backup rather than a newer invalid backup" do
    backup(at: 1.hour.ago).update!(verification_state: "invalid")
    only_valid = backup(at: 2.hours.ago)
    old_invalid = backup(at: 3.hours.ago).tap { |record| record.update!(verification_state: "invalid") }
    result = described_class.new(root: @root, keep_count: 1, keep_days: 30).call
    expect(result.blocked).to include(only_valid.uuid)
    expect(only_valid.reload.state).to eq("completed")
    expect(old_invalid.reload.state).to eq("deleted")
  end

  it "protects the newest completed backup when none is valid" do
    newest = backup(at: 1.hour.ago).tap { |record| record.update!(verification_state: "invalid") }
    older = backup(at: 2.hours.ago).tap { |record| record.update!(verification_state: "invalid") }
    expect(described_class.new(root: @root).eligible?(newest)).to be(false)
    expect(described_class.new(root: @root).eligible?(older)).to be(true)
  end

  it "tombstones an absent artifact and restores state after filesystem failure" do
    backup(at: 1.hour.ago)
    absent = backup(at: 2.hours.ago)
    FileUtils.rm_r(@root.path.join(absent.artifact_relative_path))
    described_class.new(root: @root).delete!(absent)
    expect(absent.reload.state).to eq("deleted")
    failing = backup(at: 3.hours.ago)
    allow(FileUtils).to receive(:remove_entry_secure).and_raise(Errno::EACCES)
    expect { described_class.new(root: @root).delete!(failing) }.to raise_error(Errno::EACCES)
    expect(failing.reload.state).to eq("completed")
  end

  it "protects the newest valid backup when a newer completed backup is invalid" do
    invalid = backup(at: 1.hour.ago)
    invalid.update!(verification_state: "invalid")
    valid = backup(at: 2.hours.ago)

    result = described_class.new(root: @root, keep_count: 0, keep_days: 0, max_bytes: 0).call

    expect(result.blocked).to include(valid.uuid)
    expect(valid.reload.state).to eq("completed")
  end

  it "protects the final completed artifact when none is valid" do
    only = backup(at: 1.hour.ago)
    only.update!(verification_state: "invalid")
    expect(described_class.new(root: @root).eligible?(only)).to be(false)
  end

  it "restores the completed state when filesystem deletion fails" do
    backup(at: 1.hour.ago)
    candidate = backup(at: 2.hours.ago)
    allow(FileUtils).to receive(:remove_entry_secure).and_raise(Errno::EACCES)

    expect { described_class.new(root: @root).delete!(candidate) }.to raise_error(Errno::EACCES)
    expect(candidate.reload.state).to eq("completed")
  end

  it "restores unprocessed batch claims when filesystem deletion fails" do
    backup(at: 1.hour.ago)
    first = backup(at: 2.hours.ago)
    second = backup(at: 3.hours.ago)
    allow(FileUtils).to receive(:remove_entry_secure).and_raise(Errno::EACCES)

    expect { described_class.new(root: @root, keep_count: 1).call }.to raise_error(Errno::EACCES)

    expect(first.reload.state).to eq("completed")
    expect(second.reload.state).to eq("completed")
  end

  it "rechecks pin protection while holding the deletion lock" do
    backup(at: 1.hour.ago)
    candidate = backup(at: 2.hours.ago)
    candidate.update!(pinned: true)

    expect { described_class.new(root: @root).delete!(candidate) }
      .to raise_error(ArgumentError, /protected/)
    expect(candidate.reload.state).to eq("completed")
    expect(@root.path.join(candidate.artifact_relative_path)).to exist
  end

  it "reclaims oldest eligible bytes while preserving pins and the recovery point" do
    newest = backup(at: 1.hour.ago)
    pinned = backup(at: 2.hours.ago, pinned: true)
    oldest = backup(at: 3.hours.ago)

    result = described_class.new(root: @root).reclaim!(bytes: oldest.stored_bytes)

    expect(result.deleted).to eq([oldest.uuid])
    expect(newest.reload.state).to eq("completed")
    expect(pinned.reload.state).to eq("completed")
  end
end
