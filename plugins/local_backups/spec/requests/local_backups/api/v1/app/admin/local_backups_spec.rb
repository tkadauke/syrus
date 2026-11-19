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

  it "returns a read-only reconstructed inventory" do
    bundle = Pathname(ENV.fetch("SYRUS_BACKUP_ROOT")).join("syrus-backup-v1-example").tap(&:mkpath)
    LocalBackups::Manifest.new(
      manifest_version: 1, backup_id: "123e4567-e89b-42d3-a456-426614174000", installation_id: "installation",
      completed_at: "2026-11-19T00:00:00Z", validated_at: "2026-11-19T00:01:00Z",
      database: { adapter: "sqlite3" }, storage: { logical_bytes: 10, stored_bytes: 8, blob_count: 1 },
      encryption_fingerprints: {}, artifact: { checksum_algorithm: "sha256", checksum: "c" * 64 }, validation: { result: "valid" }
    ).write_once(bundle.join("manifest.json"))
    sign_in_as(admin)

    get "/api/v1/app/admin/local_backups"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("configured" => true, "backups" => [ include("uuid" => "123e4567-e89b-42d3-a456-426614174000", "verification_state" => "valid") ])
  end
end
