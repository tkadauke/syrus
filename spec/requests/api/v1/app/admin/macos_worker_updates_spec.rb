require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/macos_worker_update", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:non_admin) { Factories.user(admin: false) }

  def parse_body = JSON.parse(response.body)

  it "requires admin access for desired release metadata" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/macos_worker_update"

    expect(response).to have_http_status(:forbidden)
  end

  it "returns configured desired macOS worker release metadata" do
    sign_in_as(admin)
    AppSetting.current.update!(
      macos_worker_desired_release: {
        "version" => "1.2.3",
        "git_sha" => "abc123",
        "artifact_url" => "https://releases.example.test/syrus-worker.tar.gz",
        "artifact_sha256" => "f" * 64,
        "retention_count" => 4,
        "poll_interval_seconds" => 120
      }
    )

    get "/api/v1/app/admin/macos_worker_update"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "enabled" => true,
      "component" => "macos-worker",
      "retention_count" => 4,
      "poll_interval_seconds" => 120
    )
    expect(parse_body.fetch("desired")).to include(
      "version" => "1.2.3",
      "git_sha" => "abc123",
      "artifact_url" => "https://releases.example.test/syrus-worker.tar.gz",
      "artifact_sha256" => "f" * 64
    )
  end

  it "records updater status on the worker instance row" do
    sign_in_as(admin)

    post "/api/v1/app/admin/macos_worker_update/report", params: {
      status: {
        hostname: "mac-mini-a",
        worker_storage_key: "storage-a",
        pool: "macos-xcode",
        state: "failed",
        message: "artifact checksum mismatch",
        current_version: "oldsha",
        target_version: "newsha",
        desired: {
          version: "1.2.3",
          git_sha: "newsha",
          artifact_url: "https://releases.example.test/syrus-worker.tar.gz",
          artifact_sha256: "f" * 64
        }
      }
    }

    expect(response).to have_http_status(:ok)
    instance = InstanceVersion.find_by!(hostname: "mac-mini-a", role: "worker")
    expect(instance.version).to eq("oldsha")
    expect(instance.desired_version).to include("git_sha" => "newsha")
    expect(instance.macos_updater_status).to include(
      "state" => "failed",
      "message" => "artifact checksum mismatch",
      "target_version" => "newsha"
    )
    expect(parse_body.dig("worker", "macos_updater_state")).to eq("failed")
  end
end
