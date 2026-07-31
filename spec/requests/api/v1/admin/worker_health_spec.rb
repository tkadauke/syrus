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
                                   data_root_used_percent: 70,
                                   cpu_pressure_full: 0.3,
                                   io_pressure_full: 0.6)
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
    expect(body.dig("hosts", 0, "windows", "1h")).to include(
      "cpu_pressure_full" => { "avg" => 0.3, "max" => 0.3 },
      "io_pressure_full" => { "avg" => 0.6, "max" => 0.6 }
    )
    expect(body.dig("hosts", 0, "recent_samples", 0)).to include(
      "hostname" => "worker-a",
      "cpu_used_percent" => 50.0
    )
  end
  it "returns bounded minute-resolution buckets with useful rollups" do
    travel_to Time.zone.parse("2026-07-31 12:30:30 UTC") do
      InstanceVersion.create!(hostname: "worker-a", role: "worker", version: "abc123",
                              started_at: 5.minutes.ago, last_heartbeat_at: 10.seconds.ago)
      WorkerHostHealthSample.create!(hostname: "worker-a", role: "worker", version: "abc123",
                                     observed_at: Time.zone.parse("2026-07-31 12:29:10 UTC"),
                                     cpu_used_percent: 50,
                                     load_1m: 1.5,
                                     memory_used_percent: 60,
                                     data_root_used_percent: 70,
                                     cpu_pressure_some: 2,
                                     io_pressure_some: 3)
      WorkerHostHealthSample.create!(hostname: "worker-a", role: "worker", version: "abc123",
                                     observed_at: Time.zone.parse("2026-07-31 12:29:50 UTC"),
                                     cpu_used_percent: 70,
                                     load_1m: 2.5,
                                     memory_used_percent: 80,
                                     data_root_used_percent: 90,
                                     cpu_pressure_some: 6,
                                     io_pressure_some: 9)

      get "/api/v1/admin/worker_health",
          params: { hostname: "worker-a", minute_bucket_window_minutes: 3 },
          headers: auth

      expect(response).to have_http_status(:ok)
      body = parse_body
      buckets = body.dig("hosts", 0, "minute_buckets")
      expect(body["minute_bucket"]).to include(
        "granularity_seconds" => 60,
        "window_minutes" => 3,
        "max_window_minutes" => 1440
      )
      expect(buckets.map { |bucket| bucket["minute"] }).to eq(
        [
          "2026-07-31T12:28:00Z",
          "2026-07-31T12:29:00Z",
          "2026-07-31T12:30:00Z"
        ]
      )

      active_bucket = buckets.second
      expect(active_bucket).to include("sample_count" => 2)
      expect(active_bucket["cpu_used_percent"]).to eq("avg" => 60.0, "max" => 70.0)
      expect(active_bucket["load_1m"]).to eq("avg" => 2.0, "max" => 2.5)
      expect(active_bucket["memory_used_percent"]).to eq("avg" => 70.0, "max" => 80.0)
      expect(active_bucket["data_root_used_percent"]).to eq("avg" => 80.0, "max" => 90.0)
      expect(active_bucket["cpu_pressure_some"]).to eq("avg" => 4.0, "max" => 6.0)
      expect(active_bucket["io_pressure_some"]).to eq("avg" => 6.0, "max" => 9.0)
      expect(buckets.first).to include("sample_count" => 0)
    end
  end
end
