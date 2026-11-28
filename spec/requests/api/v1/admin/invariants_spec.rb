require "rails_helper"

RSpec.describe "API: /api/v1/admin/invariants", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let!(:admin_token) { admin.generate_api_token! }

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  def stranded_approved_job
    job = Factories.job_with_run(state: "approved", workflow_attrs: { state: "succeeded" }, run_attrs: { state: "succeeded" })
    job.update_columns(approved_at: 3.hours.ago)
    job.runs.update_all(updated_at: 3.hours.ago)
    job.workflows.update_all(updated_at: 3.hours.ago)
    job
  end

  it "401s without a token" do
    get "/api/v1/admin/invariants"

    expect(response).to have_http_status(:unauthorized)
  end

  it "403s for a non-admin token" do
    user = Factories.user(admin: false)
    Factories.user(admin: true)

    get "/api/v1/admin/invariants", headers: auth(user.generate_api_token!)

    expect(response).to have_http_status(:forbidden)
  end

  it "returns a clean evaluation of every invariant" do
    get "/api/v1/admin/invariants", headers: auth

    expect(response).to be_successful
    body = parse_body
    expect(body.keys.first).to eq("v")
    expect(body).to include("ok" => true, "violations" => [], "scope" => { "all" => true })
    expect(body["invariants"].map { |entry| entry["key"] }).to eq(Invariants.keys)
  end

  it "returns current violations annotated with the monitor's recorded episode" do
    job = stranded_approved_job
    InvariantMonitorJob.perform_now

    get "/api/v1/admin/invariants", headers: auth

    body = parse_body
    expect(body["ok"]).to be(false)
    violation = body["violations"].sole
    expect(violation).to include("invariant" => "landing_progress", "fingerprint" => "landing_progress:Job:#{job.id}", "subject_id" => job.id,
                                 "severity" => "critical", "detection_count" => 1)
    expect(violation["first_detected_at"]).to be_present
    expect(violation["message"]).to include(job.slug)
    expect(violation.dig("details", "job", "id")).to eq(job.id)
  end

  it "filters by invariant and by Job" do
    job = stranded_approved_job

    get "/api/v1/admin/invariants", params: { only: "retry_storms" }, headers: auth
    expect(parse_body["invariants"].map { |entry| entry["key"] }).to eq(%w[retry_storms])
    expect(parse_body["violations"]).to be_empty

    get "/api/v1/admin/invariants", params: { job_id: (job.id + 1).to_s }, headers: auth
    expect(parse_body["violations"]).to be_empty

    get "/api/v1/admin/invariants", params: { job_id: job.id.to_s }, headers: auth
    expect(parse_body["violations"].map { |entry| entry["subject_id"] }).to eq([ job.id ])
  end

  it "lists recently resolved episodes on request" do
    job = stranded_approved_job
    InvariantMonitorJob.perform_now
    job.update_columns(state: "closed")
    InvariantMonitorJob.perform_now

    get "/api/v1/admin/invariants", params: { include_resolved: "true" }, headers: auth

    expect(parse_body["recently_resolved"].map { |entry| entry["subject_id"] }).to eq([ job.id ])
  end

  it "rejects an unknown invariant with a stable error code" do
    get "/api/v1/admin/invariants", params: { only: "nope" }, headers: auth

    expect(response).to have_http_status(:bad_request)
    expect(parse_body.dig("error", "code")).to eq("unknown_invariant")
    expect(parse_body.dig("error", "message")).to include("nope", "retry_storms")
  end
end
