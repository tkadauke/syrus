require "rails_helper"

RSpec.describe "API: /api/v1/admin/macos_worker_releases", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:auth) { { "Authorization" => "Bearer #{admin.generate_api_token!}" } }
  let(:plain_auth) { { "Authorization" => "Bearer #{Factories.user(admin: false).generate_api_token!}" } }
  let(:artifact_bytes) { "fake worker release tarball" }
  let(:artifact_sha) { Digest::SHA256.hexdigest(artifact_bytes) }

  def parse_body = JSON.parse(response.body)

  def upload(git_sha: "50d35be290", sha256: artifact_sha, headers: auth)
    post "/api/v1/admin/macos_worker_releases", headers: headers, params: {
      artifact: Rack::Test::UploadedFile.new(StringIO.new(artifact_bytes), "application/gzip", true,
        original_filename: "syrus-worker-macos-arm64-#{git_sha}.tar.gz"),
      git_sha: git_sha, version: "0.1.15", artifact_sha256: sha256, artifact_signature: "c2lnbmVk\n"
    }
  end

  def mac_worker!(hostname, version:, fresh: true, updater: {})
    InstanceVersion.create!(
      hostname: hostname, role: "worker", version: version,
      started_at: 1.hour.ago, last_heartbeat_at: fresh ? Time.current : 2.days.ago,
      capabilities: { "os" => [ "macos" ] }, macos_updater_status: updater
    )
  end

  it "requires an admin token" do
    upload(headers: {})
    expect(response).to have_http_status(:unauthorized)
    upload(headers: plain_auth)
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/macos_worker_releases/activate", params: { git_sha: "50d35be290" },
      headers: { "Authorization" => "Bearer #{McpInvocationContext.issue_for_app_macos_worker}" }
    expect(response).to have_http_status(:unauthorized).or have_http_status(:forbidden)
    expect(AppSetting.macos_worker_desired_release).to eq({})
  end

  it "stores an uploaded artifact and activates it as an immediate rollout" do
    upload
    expect(response).to have_http_status(:created)
    expect(parse_body).to include("git_sha" => "50d35be290", "artifact_sha256" => artifact_sha)

    post "/api/v1/admin/macos_worker_releases/activate", params: { git_sha: "50d35be290" }, headers: auth

    expect(response).to have_http_status(:ok)
    expect(AppSetting.macos_worker_desired_release).to include(
      "git_sha" => "50d35be290", "artifact_sha256" => artifact_sha, "artifact_signature" => "c2lnbmVk",
      "artifact_name" => "syrus-worker-macos-arm64-50d35be290.tar.gz", "rollout" => "immediate",
      "poll_interval_seconds" => 60
    )
    expect(AppSetting.macos_worker_desired_release["artifact_url"]).to end_with("/api/v1/app/admin/macos_worker_update/artifact")
  end

  it "rejects an upload whose bytes do not match the declared digest" do
    upload(sha256: "0" * 64)

    expect(response).to have_http_status(:unprocessable_content)
    expect(MacosWorkerRelease.blob_for("50d35be290")).to be_nil
  end

  it "refuses to activate a revision that was never uploaded" do
    post "/api/v1/admin/macos_worker_releases/activate", params: { git_sha: "deadbeef00" }, headers: auth

    expect(response).to have_http_status(:bad_request)
    expect(AppSetting.macos_worker_desired_release).to eq({})
  end

  it "reports which Mac workers run the active release, counting an activated release still draining" do
    upload
    post "/api/v1/admin/macos_worker_releases/activate", params: { git_sha: "50d35be290" }, headers: auth
    mac_worker!("mac-current", version: "50d35be290")
    mac_worker!("mac-draining", version: "16254d1666", updater: { "state" => "restarting", "current_version" => "50d35be290" })
    mac_worker!("mac-behind", version: "16254d1666", updater: { "state" => "updating", "current_version" => "16254d1666" })
    mac_worker!("mac-offline", version: "16254d1666", fresh: false)
    InstanceVersion.create!(hostname: "linux-pod", role: "worker", version: "16254d1666",
      started_at: 1.hour.ago, last_heartbeat_at: Time.current, capabilities: { "os" => [ "linux" ] })

    get "/api/v1/admin/macos_worker_releases/status", headers: auth

    workers = parse_body.fetch("workers").to_h { |w| [ w["hostname"], w.slice("live", "current") ] }
    expect(parse_body["desired_git_sha"]).to eq("50d35be290")
    expect(workers).to eq(
      "mac-current" => { "live" => true, "current" => true },
      "mac-draining" => { "live" => true, "current" => true },
      "mac-behind" => { "live" => true, "current" => false },
      "mac-offline" => { "live" => false, "current" => false }
    )
  end
end
