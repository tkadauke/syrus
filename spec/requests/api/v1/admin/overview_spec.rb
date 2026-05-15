require "rails_helper"

RSpec.describe "API: /api/v1/admin/overview", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  describe "GET /api/v1/admin/overview" do
    it "401s without a token" do
      get "/api/v1/admin/overview"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the tile-shaped rollup as JSON" do
      get "/api/v1/admin/overview", headers: auth
      expect(response).to be_successful
      body = parse_body
      expect(body).to have_key("active_runs")
      expect(body).to have_key("queued_runs")
      expect(body).to have_key("recent_failures_24h")
      expect(body).to have_key("github_rate_limits")
      expect(body).to have_key("agent_session_capture_rate")
      expect(body).not_to have_key("claude_session_capture_rate")
      expect(body).to have_key("workers")
      expect(body).to have_key("recurring")
      expect(body).to have_key("stuck")
    end

    it "reports Codex-backed captured sessions under the agent-neutral key" do
      job = Factories.job(user: admin)
      run = job.initial_run
      run.update!(state: "succeeded", agent_provider: "codex", finished_at: Time.current)
      run.step.update!(kind: "implement")
      ClaudeSession.create!(resumable: run, provider: "codex",
                            session_id: "codex-thread", transcript_jsonl: "{}\n")

      get "/api/v1/admin/overview", headers: auth

      expect(parse_body["agent_session_capture_rate"]).to eq(
        "total" => 1,
        "captured" => 1,
        "rate" => 1.0
      )
      expect(parse_body).not_to have_key("claude_session_capture_rate")
    end

    it "surfaces a stuck Run in the watchlist" do
      job = Factories.job(user: admin)
      run = job.initial_run
      run.update_columns(state: "running",
                         started_at: 10.minutes.ago,
                         last_heartbeat_at: 10.minutes.ago)
      get "/api/v1/admin/overview", headers: auth
      stuck = parse_body["stuck"]
      expect(stuck).not_to be_empty
      expect(stuck.first["kind"]).to eq("stale_heartbeat")
      expect(stuck.first["run_id"]).to eq(run.id)
    end
  end

  describe "GET /api/v1/admin/stuck" do
    it "returns the same items the overview's stuck array does, but standalone" do
      job = Factories.job(user: admin)
      run = job.initial_run
      run.update_columns(state: "running",
                         started_at: 10.minutes.ago,
                         last_heartbeat_at: 10.minutes.ago)
      get "/api/v1/admin/stuck", headers: auth
      expect(response).to be_successful
      items = parse_body["items"]
      expect(items.first["kind"]).to eq("stale_heartbeat")
      expect(items.first["severity"]).to eq("warn")
    end
  end
end
