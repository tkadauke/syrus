require "rails_helper"

RSpec.describe "API: /api/v1/admin/runs", type: :request do
  let!(:admin)        { Factories.user }
  let!(:admin_token)  { admin.generate_api_token! }
  let(:non_admin)     { Factories.user }
  let(:non_admin_tok) { non_admin.generate_api_token! }

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  let(:job) { Factories.job(user: admin) }

  describe "auth" do
    it "401s without a token" do
      get "/api/v1/admin/runs"
      expect(response).to have_http_status(:unauthorized)
    end

    it "403s for a non-admin token" do
      get "/api/v1/admin/runs", headers: auth(non_admin_tok)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/admin/runs" do
    let!(:run_a) do
      r = job.initial_run
      r.update!(state: "succeeded", started_at: 2.hours.ago, finished_at: 90.minutes.ago)
      r
    end
    let!(:run_b) do
      step = job.workflows.last.steps.find_by(kind: "implement")
      Run.create!(job: job, step: step, trigger_kind: "pr_comment",
                  state: "failed", started_at: 1.hour.ago, finished_at: 30.minutes.ago)
    end

    it "returns the compact shape with workflow/step context" do
      get "/api/v1/admin/runs", headers: auth
      expect(response).to be_successful

      row = parse_body["runs"].find { |r| r["id"] == run_b.id }
      expect(row).to include(
        "id"           => run_b.id,
        "state"        => "failed",
        "trigger_kind" => "pr_comment",
        "job_id"       => job.id,
        "step_kind"    => "implement"
      )
    end

    it "filters by state" do
      get "/api/v1/admin/runs", params: { state: "failed" }, headers: auth
      ids = parse_body["runs"].map { |r| r["id"] }
      expect(ids).to     include(run_b.id)
      expect(ids).not_to include(run_a.id)
    end

    it "filters by trigger_kind" do
      get "/api/v1/admin/runs", params: { trigger_kind: "pr_comment" }, headers: auth
      ids = parse_body["runs"].map { |r| r["id"] }
      expect(ids).to     include(run_b.id)
      expect(ids).not_to include(run_a.id)
    end

    it "filters by job_id" do
      other_job = Factories.job(user: admin, issue_number: 99,
                                 repository: Factories.repository(user: admin, owner: "globex", name: "things"))
      foreign_run = other_job.initial_run

      get "/api/v1/admin/runs", params: { job_id: job.id }, headers: auth
      ids = parse_body["runs"].map { |r| r["id"] }
      expect(ids).to     include(run_a.id)
      expect(ids).not_to include(foreign_run.id)
    end

    it "filters by ?since (gte against finished_at COALESCE started_at)" do
      get "/api/v1/admin/runs", params: { since: 45.minutes.ago.iso8601 }, headers: auth
      ids = parse_body["runs"].map { |r| r["id"] }
      expect(ids).to     include(run_b.id)        # finished 30m ago — passes
      expect(ids).not_to include(run_a.id)        # finished 90m ago — too old
    end

    it "ignores garbage in ?since (degrades to wide window, not 400)" do
      get "/api/v1/admin/runs", params: { since: "not-a-timestamp" }, headers: auth
      expect(response).to be_successful
    end

    it "respects ?per up to MAX_PER and returns total count" do
      # Cap test — confirm the per param is honored.
      get "/api/v1/admin/runs", params: { per: 1 }, headers: auth
      expect(parse_body["per"]).to eq(1)
      expect(parse_body["runs"].size).to eq(1)
      expect(parse_body["total"]).to be >= 2
    end

    it "clamps ?per to MAX_PER (100)" do
      get "/api/v1/admin/runs", params: { per: 9999 }, headers: auth
      expect(parse_body["per"]).to eq(100)
    end

    it "paginates via ?page" do
      get "/api/v1/admin/runs", params: { per: 1, page: 2 }, headers: auth
      expect(parse_body["page"]).to eq(2)
      expect(parse_body["runs"].size).to be <= 1
    end
  end
end
