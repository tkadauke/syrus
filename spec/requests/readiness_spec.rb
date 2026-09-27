require "rails_helper"

RSpec.describe "GET /readyz", type: :request do
  def parse_body = JSON.parse(response.body)

  before do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
    AppSetting.current.update!(polling_paused: false, runs_paused: false)
  end

  it "does not require authentication or per-user credential checks" do
    allow(GithubClient).to receive(:for_user).and_raise("per-user readiness should not run")
    solid_queue_process

    get "/readyz"

    expect(response).to have_http_status(:ok)
    keys = parse_body.fetch("checks").map { |check| check.fetch("key") }
    expect(keys).to include("web_config", "worker_queue", "polling_runs", "storage")
    expect(keys).not_to include("github", "agent_provider")
  end

  it "reports not-ready when no Solid Queue workers are registered" do
    get "/readyz"

    expect(response).to have_http_status(:service_unavailable)
    expect(parse_body).to include("status" => "error")
    worker_check = parse_body.fetch("checks").find { |check| check.fetch("key") == "worker_queue" }
    expect(worker_check).to include(
      "status" => "error",
      "message" => "No Solid Queue worker processes are registered."
    )
  end

  def solid_queue_process
    SolidQueue::Process.create!(
      kind: "Worker",
      name: "worker-1",
      hostname: "worker",
      pid: 123,
      last_heartbeat_at: Time.current,
      created_at: Time.current,
      metadata: { "queues" => [ "runs" ] }
    )
  end
end
