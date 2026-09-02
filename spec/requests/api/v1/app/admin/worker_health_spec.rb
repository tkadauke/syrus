require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/worker_health", type: :request do
  let(:admin) { Factories.user(admin: true) }

  def parse_body = JSON.parse(response.body)

  before { sign_in_as(admin) }

  it "omits raw metrics by default from the browser-facing payload" do
    InstanceVersion.create!(hostname: "worker-a", role: "worker", version: "abc123",
                            started_at: 5.minutes.ago, last_heartbeat_at: 10.seconds.ago)
    WorkerHostHealthSample.create!(hostname: "worker-a", role: "worker", version: "abc123",
                                   observed_at: 1.minute.ago,
                                   cpu_used_percent: 42,
                                   raw_metrics: { "large" => "payload" })

    get "/api/v1/app/admin/worker_health"

    expect(response).to have_http_status(:ok)
    sample = parse_body.dig("current", 0, "sample")
    expect(sample).to include("cpu_used_percent" => 42.0)
    expect(sample).not_to have_key("raw_metrics")
  end

  it "can include raw metrics when explicitly requested" do
    InstanceVersion.create!(hostname: "worker-a", role: "worker", version: "abc123",
                            started_at: 5.minutes.ago, last_heartbeat_at: 10.seconds.ago)
    WorkerHostHealthSample.create!(hostname: "worker-a", role: "worker", version: "abc123",
                                   observed_at: 1.minute.ago,
                                   cpu_used_percent: 42,
                                   raw_metrics: { "large" => "payload" })

    get "/api/v1/app/admin/worker_health", params: { include_raw_metrics: "true" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("current", 0, "sample", "raw_metrics")).to eq("large" => "payload")
  end
end
