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

  it "accepts scoped macOS worker credentials for desired release metadata" do
    token = McpInvocationContext.issue_for_app_macos_worker
    allow(OperationalLogging).to receive(:ingest)
    AppSetting.current.update!(
      macos_worker_desired_release: {
        "version" => "1.2.3",
        "git_sha" => "abc123",
        "artifact_url" => "https://releases.example.test/syrus-worker.tar.gz",
        "artifact_sha256" => "f" * 64
      }
    )

    get "/api/v1/app/admin/macos_worker_update",
        params: { worker_storage_key: "storage-a", hostname: "mac-mini-a" },
        headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("component" => "macos-worker")
    expect(OperationalLogging).to have_received(:ingest).with(
      hash_including(
        source: "macos_worker_update",
        message: "macOS worker update credential allowed",
        context: hash_including(
          method: "GET",
          path: "/api/v1/app/admin/macos_worker_update",
          status: 200,
          hostname: "mac-mini-a",
          worker_storage_key: "storage-a"
        )
      )
    )
  end

  it "accepts scoped macOS worker credentials for updater reports" do
    token = McpInvocationContext.issue_for_app_macos_worker

    post "/api/v1/app/admin/macos_worker_update/report",
         params: { status: { hostname: "mac-mini-a", state: "current", current_version: "abc123" } },
         headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    expect(InstanceVersion.find_by!(hostname: "mac-mini-a", role: "worker").macos_updater_state).to eq("current")
  end

  it "rejects scoped macOS worker credentials outside the update endpoints" do
    token = McpInvocationContext.issue_for_app_macos_worker

    get "/api/v1/app/repositories", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns configured desired macOS worker release metadata without enabling unselected workers" do
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
      "enabled" => false,
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

  it "enables the desired release only for the worker currently marked updating" do
    sign_in_as(admin)
    AppSetting.current.update!(
      macos_worker_desired_release: {
        "version" => "1.2.3",
        "git_sha" => "abc123",
        "artifact_url" => "https://releases.example.test/syrus-worker.tar.gz",
        "artifact_sha256" => "f" * 64
      }
    )
    MacosWorkerDrain.create!(
      worker_storage_key: "storage-a",
      hostname: "mac-mini-a",
      state: "updating",
      desired_git_sha: "abc123",
      desired_version: { "git_sha" => "abc123" },
      drain_started_at: Time.current,
      update_started_at: Time.current
    )

    get "/api/v1/app/admin/macos_worker_update", params: { worker_storage_key: "storage-a", hostname: "mac-mini-a" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("enabled" => true)
    expect(parse_body.fetch("drain")).to include("state" => "updating")
  end

  it "keeps a selected worker disabled while it is still draining active work" do
    sign_in_as(admin)
    AppSetting.current.update!(
      macos_worker_desired_release: {
        "version" => "1.2.3",
        "git_sha" => "abc123",
        "artifact_url" => "https://releases.example.test/syrus-worker.tar.gz",
        "artifact_sha256" => "f" * 64
      }
    )
    MacosWorkerDrain.create!(
      worker_storage_key: "storage-a",
      hostname: "mac-mini-a",
      state: "draining",
      desired_git_sha: "abc123",
      desired_version: { "git_sha" => "abc123" },
      drain_started_at: Time.current
    )

    get "/api/v1/app/admin/macos_worker_update", params: { worker_storage_key: "storage-a", hostname: "mac-mini-a" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("enabled" => false)
    expect(parse_body.fetch("drain")).to include("state" => "draining")
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

  it "returns a drain directive for the requesting worker" do
    sign_in_as(admin)
    MacosWorkerDrain.create!(
      worker_storage_key: "storage-a",
      hostname: "mac-mini-a",
      state: "updating",
      desired_git_sha: "newsha",
      desired_version: { "git_sha" => "newsha" },
      drain_started_at: Time.current
    )

    get "/api/v1/app/admin/macos_worker_update", params: { worker_storage_key: "storage-a", hostname: "mac-mini-a" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("drain")).to include(
      "state" => "updating",
      "worker_storage_key" => "storage-a",
      "hostname" => "mac-mini-a",
      "desired_git_sha" => "newsha"
    )
  end

  it "syncs active drain identity from updater reports" do
    sign_in_as(admin)
    MacosWorkerDrain.create!(hostname: "mac-mini-a", state: "draining", desired_git_sha: "newsha")

    post "/api/v1/app/admin/macos_worker_update/report", params: {
      status: {
        hostname: "mac-mini-a",
        worker_storage_key: "storage-a",
        state: "idle",
        current_version: "oldsha",
        desired: { git_sha: "newsha" }
      }
    }

    expect(response).to have_http_status(:ok)
    expect(MacosWorkerDrain.sole.worker_storage_key).to eq("storage-a")
  end

  it "advances rolling update orchestration" do
    sign_in_as(admin)
    AppSetting.current.update!(macos_worker_desired_release: { "version" => "1.2.3", "git_sha" => "newsha", "artifact_url" => "https://releases.example.test/worker.tgz" })
    InstanceVersion.create!(
      hostname: "mac-mini-a",
      role: "worker",
      version: "oldsha",
      started_at: 5.minutes.ago,
      last_heartbeat_at: Time.current,
      capabilities: { "os" => [ "macos" ] }
    )
    WorkerHostHealthSample.create!(hostname: "mac-mini-a", worker_storage_key: "storage-a", role: "worker", version: "oldsha", observed_at: Time.current, cpu_used_percent: 20)

    post "/api/v1/app/admin/macos_worker_update/advance"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("state" => "updating")
    expect(parse_body.dig("drain", "worker_storage_key")).to eq("storage-a")
  end
end
