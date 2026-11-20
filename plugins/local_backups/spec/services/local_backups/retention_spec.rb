require "rails_helper"

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
end
