require "rails_helper"

RSpec.describe "App API job execution waterfall", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job_record(user: user, repository: repo, state: "running", issue_title: "Fix the aqueducts") }

  def parse_body = JSON.parse(response.body)

  def build_workflow_with_step(for_job: job)
    workflow = Workflow.create!(
      job: for_job,
      trigger_kind: "initial",
      state: "running",
      started_at: 10.minutes.ago,
      worker_hostname: "worker-a",
      worker_storage_key: "wf-123-storage"
    )
    step = workflow.steps.create!(kind: "prepare", position: 0, state: "succeeded", started_at: 10.minutes.ago, finished_at: 9.minutes.ago)
    step.runs.create!(job: for_job, trigger_kind: "initial", state: "succeeded", iteration: 1, started_at: 10.minutes.ago, finished_at: 9.minutes.ago, user: user)
    workflow
  end

  it "returns Step/Run timing without worker-identity fields for a non-admin" do
    user.update!(global_role: "user")
    sign_in_as(user)
    workflow = build_workflow_with_step

    get "/api/v1/app/jobs/#{job.id}/waterfall", params: { workflow_id: workflow.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("workflow", "id")).to eq(workflow.id)
    expect(body.dig("workflow", "status")).to eq("running")
    expect(body["workflow"]).not_to have_key("hostname")
    expect(body["workflow"]).not_to have_key("pid")
    expect(body["workflow"]).not_to have_key("worker_storage_key")
    expect(body["workflow"]).not_to have_key("queue_role")

    step_payload = body.fetch("steps").first
    expect(step_payload["status"]).to eq("succeeded")
    expect(step_payload["started_at"]).to be_present
    expect(step_payload).not_to have_key("hostname")
    expect(step_payload).not_to have_key("pid")
    expect(step_payload).not_to have_key("worker_storage_key")
    expect(step_payload).not_to have_key("queue_role")
    expect(step_payload.fetch("runs").first).to include("status" => "succeeded")
  end

  it "returns full worker-identity fields for an admin" do
    user.update!(global_role: "admin")
    sign_in_as(user)
    workflow = build_workflow_with_step

    get "/api/v1/app/jobs/#{job.id}/waterfall", params: { workflow_id: workflow.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("workflow", "hostname")).to eq("worker-a")
    expect(body.dig("workflow", "worker_storage_key")).to eq("wf-123-storage")
    step_payload = body.fetch("steps").first
    expect(step_payload).to have_key("hostname")
    expect(step_payload).to have_key("worker_storage_key")
  end

  it "rejects a workflow_id that belongs to a different Job" do
    sign_in_as(user)
    other_job = Factories.job_record(user: user, repository: repo, state: "running", issue_number: 43)
    other_workflow = build_workflow_with_step(for_job: other_job)

    get "/api/v1/app/jobs/#{job.id}/waterfall", params: { workflow_id: other_workflow.id }

    expect(response).to have_http_status(:not_found)
  end

  it "rejects a user without visibility into the Job" do
    outsider = Factories.user
    sign_in_as(outsider)
    workflow = build_workflow_with_step

    get "/api/v1/app/jobs/#{job.id}/waterfall", params: { workflow_id: workflow.id }

    expect(response).to have_http_status(:not_found)
  end
end
