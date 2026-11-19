require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/local_backups", type: :request do
  let(:admin) { Factories.user }

  around do |example|
    old_root = ENV["SYRUS_BACKUP_ROOT"]
    old_data = ENV["SYRUS_DATA_ROOT"]
    Dir.mktmpdir do |dir|
      ENV["SYRUS_BACKUP_ROOT"] = dir
      ENV["SYRUS_DATA_ROOT"] = nil
      example.run
    end
  ensure
    ENV["SYRUS_BACKUP_ROOT"] = old_root
    ENV["SYRUS_DATA_ROOT"] = old_data
  end

  it "requires an administrator" do
    get "/api/v1/app/admin/local_backups"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns the cached inventory without scanning or mutating it" do
    backup = LocalBackups::Backup.create!(
      uuid: "123e4567-e89b-42d3-a456-426614174000", state: "completed", artifact_path: "syrus-backup-v1-example",
      manifest_version: 1, logical_bytes: 10, stored_bytes: 8, blob_count: 1, checksum_algorithm: "sha256",
      checksum: "c" * 64, verification_state: "valid", encryption_fingerprints: {}
    )
    allow(LocalBackups::InventoryScanner).to receive(:new).and_raise("GET must not scan")
    sign_in_as(admin)

    get "/api/v1/app/admin/local_backups"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("configured" => true, "backups" => [ include("uuid" => "123e4567-e89b-42d3-a456-426614174000", "verification_state" => "valid") ])
    expect(backup.reload).to be_persisted
  end
end
