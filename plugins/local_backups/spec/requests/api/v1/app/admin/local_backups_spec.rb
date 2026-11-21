require "rails_helper"
require_relative "../../../../../support/resolved_tmpdir"

RSpec.describe "API: local backup inventory", type: :request do
  let(:admin) { Factories.user(admin: true) }

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

  it "forbids every backup operation to a signed-in non-administrator" do
    admin
    sign_in_as(Factories.user(global_role: "user"))
    requests = [
      -> { get "/api/v1/app/admin/local_backups" },
      -> { post "/api/v1/app/admin/local_backups" },
      -> { post "/api/v1/app/admin/local_backups/missing/validate" },
      -> { post "/api/v1/app/admin/local_backups/missing/pin" },
      -> { delete "/api/v1/app/admin/local_backups/missing/pin" },
      -> { delete "/api/v1/app/admin/local_backups/missing" },
      -> { get "/api/v1/app/admin/local_backups/missing/download" }
    ]

    requests.each_with_index do |request, index|
      request.call
      expect(response).to have_http_status(:forbidden), "request #{index} unexpectedly returned #{response.status}"
    end
    expect(AdminAction.where(action: "local_backup_downloaded")).to be_empty
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

  it "queues on-demand creation for an administrator" do
    sign_in_as(admin)
    expect { post "/api/v1/app/admin/local_backups" }.to have_enqueued_job(LocalBackups::CreateJob).with(reason: "manual")
    expect(response).to have_http_status(:accepted)
  end

  it "validates, pins, unpins, and queues eligible deletion" do
    sign_in_as(admin)
    backup = create_backup
    allow_any_instance_of(LocalBackups::Validator).to receive(:call) { |_, record| record.update!(verification_state: "valid") }
    post "/api/v1/app/admin/local_backups/#{backup.uuid}/validate"
    expect(response).to have_http_status(:ok)
    post "/api/v1/app/admin/local_backups/#{backup.uuid}/pin"
    expect(backup.reload).to be_pinned
    delete "/api/v1/app/admin/local_backups/#{backup.uuid}/pin"
    expect(backup.reload).not_to be_pinned
    create_backup(completed_at: 1.minute.from_now)
    expect { delete "/api/v1/app/admin/local_backups/#{backup.uuid}" }.to have_enqueued_job(LocalBackups::DeleteJob).with(backup.id)
    expect(response).to have_http_status(:accepted)
  end

  it "streams full and ranged tar downloads and audits each request" do
    sign_in_as(admin)
    backup = create_backup
    Pathname.new(ENV.fetch("SYRUS_BACKUP_ROOT")).join(backup.artifact_relative_path, "payload.txt").write("recovery payload")
    get "/api/v1/app/admin/local_backups/#{backup.uuid}/download"
    full = response.body
    expect(response).to have_http_status(:ok)
    expect(AdminAction.where(action: "local_backup_downloaded").count).to eq(1)
    expect(full).to include("payload.txt", "recovery payload")
    get "/api/v1/app/admin/local_backups/#{backup.uuid}/download", headers: { "Range" => "bytes=0-31" }
    expect(response).to have_http_status(:partial_content)
    expect(response.headers.fetch("Content-Range")).to match(/\Abytes 0-31\/\d+\z/)
    expect(response.body).to eq(full.byteslice(0, 32))
  end

  it "rejects an unsatisfiable download range" do
    sign_in_as(admin)
    backup = create_backup
    get "/api/v1/app/admin/local_backups/#{backup.uuid}/download", headers: { "Range" => "bytes=999999-" }
    expect(response).to have_http_status(:range_not_satisfiable)
  end

  def create_backup(completed_at: Time.current)
    uuid = SecureRandom.uuid
    Pathname.new(ENV.fetch("SYRUS_BACKUP_ROOT")).join(uuid).mkdir
    LocalBackups::Backup.create!(uuid:, state: "completed", reason: "manual", artifact_relative_path: uuid,
      manifest_version: "1", completed_at:, validated_at: completed_at, verification_state: "valid", stored_bytes: 10)
  end
end
