require "rails_helper"

RSpec.describe "API: /api/v1/timeline/workflows/:id", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }

  let(:repository) { Factories.repository(user: admin) }
  let(:job) { Factories.job_record(user: admin, repository: repository, state: "running") }

  it "requires an API token" do
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago)

    get "/api/v1/timeline/workflows/#{workflow.id}"

    expect(response).to have_http_status(:unauthorized)
  end

  it "requires an admin user" do
    admin # ensure admin is the first user created, so this one is not auto-promoted
    non_admin = Factories.user
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago)

    get "/api/v1/timeline/workflows/#{workflow.id}", headers: { "Authorization" => "Bearer #{non_admin.generate_api_token!}" }

    expect(response).to have_http_status(:forbidden)
  end

  it "returns the ordered Step/Run waterfall for a workflow" do
    workflow = Workflow.create!(
      job: job, trigger_kind: "initial", state: "running",
      started_at: 20.minutes.ago, worker_hostname: "worker-a"
    )
    prepare_step = workflow.steps.create!(kind: "prepare", position: 0, state: "succeeded", started_at: 20.minutes.ago, finished_at: 19.minutes.ago)
    implement_step = workflow.steps.create!(kind: "implement", position: 1, state: "running", started_at: 19.minutes.ago)
    run = Run.create!(
      job: job, user: admin, step: implement_step, trigger_kind: "initial", agent_provider: "claude",
      state: "running", started_at: 19.minutes.ago
    )

    get "/api/v1/timeline/workflows/#{workflow.id}", headers: auth

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.dig("workflow", "id")).to eq(workflow.id)
    expect(body.dig("workflow", "hostname")).to eq("worker-a")
    expect(body.fetch("steps").map { |step| step["id"] }).to eq([ prepare_step.id, implement_step.id ])
    expect(body.dig("steps", 1, "runs", 0, "id")).to eq(run.id)
  end

  it "404s for an unknown workflow id" do
    get "/api/v1/timeline/workflows/999999999", headers: auth

    expect(response).to have_http_status(:not_found)
  end
end
