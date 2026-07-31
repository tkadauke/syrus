require "rails_helper"

RSpec.describe "API: /api/v1/admin/worker_health", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  it "401s without a token" do
    get "/api/v1/admin/worker_health"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns live worker status and compact historical windows" do
    InstanceVersion.create!(hostname: "worker-a", role: "worker", version: "abc123",
                            started_at: 5.minutes.ago, last_heartbeat_at: 10.seconds.ago)
    WorkerHostHealthSample.create!(hostname: "worker-a", role: "worker", version: "abc123",
                                   observed_at: 10.minutes.ago,
                                   cpu_used_percent: 50,
                                   memory_used_percent: 60,
                                   data_root_used_percent: 70)
    WorkerHostHealthSample.create!(hostname: "worker-b", role: "worker", version: "abc123",
                                   observed_at: 10.minutes.ago,
                                   cpu_used_percent: 99,
                                   memory_used_percent: 60,
                                   data_root_used_percent: 70)

    get "/api/v1/admin/worker_health", params: { hostname: "worker-a" }, headers: auth

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["current"].map { |worker| worker["hostname"] }).to eq([ "worker-a" ])
    expect(body["hosts"].map { |host| host["hostname"] }).to eq([ "worker-a" ])
    expect(body.dig("hosts", 0, "windows", "1h")).to include("sample_count" => 1)
    expect(body.dig("hosts", 0, "recent_samples", 0)).to include(
      "hostname" => "worker-a",
      "cpu_used_percent" => 50.0
    )
  end
end
