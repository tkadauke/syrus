require "rails_helper"

RSpec.describe "API: local backup inventory", type: :request do
  let(:admin) { Factories.user }

  before do
    PluginRecord.find_by!(name: "local_backups").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  around do |example|
    previous = ENV["SYRUS_BACKUP_ROOT"]
    Dir.mktmpdir do |root|
      ENV["SYRUS_BACKUP_ROOT"] = root
      example.run
    end
  ensure
    ENV["SYRUS_BACKUP_ROOT"] = previous
  end

  it "requires an administrator" do
    get "/api/v1/app/admin/local_backups"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns rediscovered sealed artifacts without mutation actions" do
    artifact = Pathname.new(ENV.fetch("SYRUS_BACKUP_ROOT")).join("sealed").tap(&:mkpath)
    uuid = SecureRandom.uuid
    LocalBackups::Manifest.write(artifact, {
      backup_id: uuid, completed_at: Time.current.iso8601,
      artifact: { logical_bytes: 1, stored_bytes: 1, blob_count: 0 },
      checksum: { algorithm: "sha256", value: "c" * 64 }
    })
    sign_in_as(admin)

    get "/api/v1/app/admin/local_backups"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).fetch("backups").sole).to include("uuid" => uuid)
    expect(response.body).not_to include("delete_url", "restore_url", "download_url")
  end
end
