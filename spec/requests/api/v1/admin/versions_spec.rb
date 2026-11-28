require "rails_helper"

RSpec.describe "API: /api/v1/admin/version", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  describe "GET /api/v1/admin/version" do
    it "401s without a token" do
      get "/api/v1/admin/version"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the request-handler identity plus every fresh instance" do
      web_a = InstanceVersion.create!(hostname: "syrus-web-aaa", role: "web", version: "abc1234",
                                       started_at: 5.minutes.ago, last_heartbeat_at: 10.seconds.ago)
      worker = InstanceVersion.create!(hostname: "syrus-worker-bbb", role: "worker", version: "abc1234",
                                       started_at: 5.minutes.ago, last_heartbeat_at: 5.seconds.ago)

      get "/api/v1/admin/version", headers: auth

      expect(response).to be_successful
      body = parse_body
      expect(body).to have_key("request_handler")
      expect(body["request_handler"]).to include("hostname", "role", "version")

      hostnames = body["instances"].map { |i| i["hostname"] }
      expect(hostnames).to contain_exactly(web_a.hostname, worker.hostname)

      web_row = body["instances"].find { |i| i["hostname"] == web_a.hostname }
      expect(web_row).to include("role" => "web", "version" => "abc1234", "stale" => false)
      expect(web_row["seconds_since_heartbeat"]).to be < 60
      expect(body["worker_health"]).to include("current", "hosts")
      expect(body.dig("worker_health", "hosts")).to eq([])
    end

    it "summarizes each worker's environment smoke verdict with the failed checks' reasons" do
      InstanceVersion.create!(hostname: "mac-mini", role: "worker", version: "abc1234", started_at: 5.minutes.ago,
        last_heartbeat_at: 5.seconds.ago, capability_diagnostics: {
          "environment_smoke" => {
            "status" => "degraded", "observed_at" => "2026-11-28T04:00:00Z", "failed" => [ "mysql_client" ],
            "checks" => { "mysql_client" => { "status" => "failed", "reason" => "no mysql_config found" }, "git" => { "status" => "passed" } }
          }
        })
      InstanceVersion.create!(hostname: "syrus-web", role: "web", version: "abc1234", started_at: 5.minutes.ago, last_heartbeat_at: 5.seconds.ago)

      get "/api/v1/admin/version", headers: auth

      rows = parse_body["instances"].index_by { |row| row["hostname"] }
      expect(rows.dig("mac-mini", "environment_smoke")).to eq(
        "status" => "degraded", "observed_at" => "2026-11-28T04:00:00Z", "failed_checks" => { "mysql_client" => "no mysql_config found" }
      )
      expect(rows.dig("syrus-web", "environment_smoke")).to be_nil
    end

    it "omits instances whose heartbeat is older than the fresh threshold" do
      InstanceVersion.create!(hostname: "syrus-web-old", role: "web", version: "old-sha",
                              started_at: 1.hour.ago, last_heartbeat_at: 10.minutes.ago)
      fresh = InstanceVersion.create!(hostname: "syrus-web-new", role: "web", version: "new-sha",
                                       started_at: 1.minute.ago, last_heartbeat_at: 5.seconds.ago)

      get "/api/v1/admin/version", headers: auth

      hostnames = parse_body["instances"].map { |i| i["hostname"] }
      expect(hostnames).to eq([ fresh.hostname ])
    end

    it "omits instances that have been gracefully finalized" do
      InstanceVersion.create!(hostname: "syrus-web-done", role: "web", version: "abc",
                              started_at: 5.minutes.ago, last_heartbeat_at: 10.seconds.ago,
                              finished_at: 5.seconds.ago, outcome: "shutdown")

      get "/api/v1/admin/version", headers: auth

      expect(parse_body["instances"]).to be_empty
    end

    it "surfaces both versions simultaneously during a rolling deploy" do
      InstanceVersion.create!(hostname: "syrus-web-old-pod", role: "web", version: "old-sha",
                              started_at: 2.minutes.ago, last_heartbeat_at: 5.seconds.ago)
      InstanceVersion.create!(hostname: "syrus-web-new-pod", role: "web", version: "new-sha",
                              started_at: 30.seconds.ago, last_heartbeat_at: 2.seconds.ago)

      get "/api/v1/admin/version", headers: auth

      versions = parse_body["instances"].map { |i| i["version"] }
      expect(versions).to contain_exactly("old-sha", "new-sha")
    end
  end
end
