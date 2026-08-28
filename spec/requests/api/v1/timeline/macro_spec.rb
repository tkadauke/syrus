require "rails_helper"

RSpec.describe "API: /api/v1/timeline/macro", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }

  let(:repository) { Factories.repository(user: admin) }
  let(:job) { Factories.job_record(user: admin, repository: repository, state: "running") }

  it "requires an API token" do
    get "/api/v1/timeline/macro"

    expect(response).to have_http_status(:unauthorized)
  end

  it "requires an admin user" do
    admin # ensure admin is the first user created, so this one is not auto-promoted
    non_admin = Factories.user
    token = non_admin.generate_api_token!

    get "/api/v1/timeline/macro", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:forbidden)
  end

  it "returns lanes filtered by repository_id, job_id, hostname, and status" do
    other_repository = Factories.repository(user: admin)
    other_job = Factories.job_record(user: admin, repository: other_repository, state: "running")

    matching = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
    Workflow.create!(job: other_job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
    Workflow.create!(job: job, trigger_kind: "initial", state: "failed", started_at: 10.minutes.ago, finished_at: 5.minutes.ago, worker_hostname: "worker-y")

    get "/api/v1/timeline/macro",
        params: { repository_id: repository.id, job_id: job.id, hostname: "worker-x", status: "running" },
        headers: auth

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    span_workflow_ids = body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }.map { |span| span.fetch("workflow_id") }
    expect(span_workflow_ids).to eq([ matching.id ])
    expect(body.fetch("lanes").map { |lane| lane.fetch("hostname") }.uniq).to eq([ "worker-x" ])
  end

  it "reuses WorkUnits::StartBlock for a currently-blocked pending workflow" do
    queued_job = Factories.job_record(user: admin, repository: repository, state: "queued")
    queued_workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: queued_job)
    queued_workflow.work_unit.block!(
      reason: "provider_availability",
      blocked_until: 10.minutes.from_now,
      details: { "provider" => "codex" }
    )

    get "/api/v1/timeline/macro", params: { job_id: queued_job.id }, headers: auth

    expect(response).to have_http_status(:ok)
    pending_entry = response.parsed_body.fetch("pending").find { |entry| entry.fetch("workflow_id") == queued_workflow.id }
    expect(pending_entry.dig("blocked", "blocked_reason")).to eq("provider_availability")
    expect(pending_entry.dig("blocked", "available")).to be(true)
    expect(pending_entry.dig("blocked", "historical")).to be(false)
  end

  it "is honest that no blocked-reason record survives for a finished workflow whose block period already resolved" do
    resolved_job = Factories.job_record(user: admin, repository: repository, state: "running")
    resolved_workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: resolved_job)
    resolved_workflow.work_unit.block!(reason: "provider_availability", blocked_until: 1.hour.ago, details: {})
    resolved_workflow.work_unit.unblock!
    resolved_workflow.update!(state: "succeeded", started_at: 3.days.ago, finished_at: 3.days.ago + 5.minutes)

    get "/api/v1/timeline/macro", params: { job_id: resolved_job.id, from: 4.days.ago.iso8601, to: Time.current.iso8601 }, headers: auth

    expect(response).to have_http_status(:ok)
    span = response.parsed_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }.find { |s| s.fetch("workflow_id") == resolved_workflow.id }
    expect(span).to be_present
    expect(span.fetch("blocked")).to include(
      "blocked_reason" => nil,
      "available" => false,
      "historical" => true
    )
    expect(response.parsed_body.fetch("pending")).to be_empty
  end
end
