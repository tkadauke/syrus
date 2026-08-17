require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/reconciler_activity", type: :request do
  def parse_body = JSON.parse(response.body)

  it "requires an admin user" do
    Factories.user
    sign_in_as(Factories.user)

    get "/api/v1/app/admin/reconciler_activity"

    expect(response).to have_http_status(:forbidden)
  end

  it "returns paginated reconciler activity for admins" do
    admin = Factories.user
    job = Factories.job(user: admin)
    workflow = job.workflows.first
    run = job.initial_run
    WorkEngineReconcilerActivityEvent.record!(
      event_type: "repair_executed",
      source: "spec",
      severity: "info",
      job_id: job.id,
      workflow_id: workflow.id,
      run_id: run.id,
      repair_action: "reenqueue_run",
      repair_status: "applied",
      message: "re-enqueued Run ##{run.id}",
      details: { status: "applied" },
      occurred_at: 1.minute.ago
    )
    sign_in_as(admin)

    get "/api/v1/app/admin/reconciler_activity", params: { event_type: "repair_executed", job_id: job.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["pagination"]).to include("total" => 1, "page" => 1)
    expect(body["event_types"]).to include("run_started", "repair_executed")
    expect(body["events"].first).to include(
      "event_type" => "repair_executed",
      "source" => "spec",
      "message" => "re-enqueued Run ##{run.id}",
      "repair_action" => "reenqueue_run",
      "repair_status" => "applied"
    )
    expect(body.dig("events", 0, "job")).to include("id" => job.id, "slug" => job.slug, "path" => "/jobs/#{job.id}")
    expect(body.dig("events", 0, "workflow")).to include("id" => workflow.id, "path" => "/jobs/#{job.id}?tab=workflows#workflow-#{workflow.id}")
    expect(body.dig("events", 0, "run")).to include("id" => run.id, "path" => "/admin/runs/#{run.id}/transcript")
  end

  it "sorts reconciler activity with an allowlisted column" do
    admin = Factories.user
    sign_in_as(admin)

    WorkEngineReconcilerActivityEvent.record!(
      event_type: "run_started",
      source: "spec",
      message: "Zulu"
    )
    WorkEngineReconcilerActivityEvent.record!(
      event_type: "run_finished",
      source: "spec",
      message: "Alpha"
    )

    get "/api/v1/app/admin/reconciler_activity", params: { sort: "message", direction: "asc" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("filters", "sort")).to eq("message")
    expect(body.dig("filters", "direction")).to eq("asc")
    expect(body.fetch("events").first.fetch("message")).to eq("Alpha")
  end
end
