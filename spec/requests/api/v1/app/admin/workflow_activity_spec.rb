require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/activity", type: :request do
  it "requires an admin user" do
    Factories.user
    non_admin = Factories.user
    sign_in_as(non_admin)

    get "/api/v1/app/admin/activity"

    expect(response).to have_http_status(:forbidden)
  end

  it "returns filtered workflow activity" do
    admin = Factories.user
    sign_in_as(admin)
    job = Factories.job_record(user: admin, state: "queued")
    WorkflowActivity.synchronously do
      WorkflowActivity.record!(
        event_type: "landing_queue_changed",
        source: "spec",
        job: job,
        reason_key: "pr_checks_failing",
        message: "Queue changed."
      )
    end

    get "/api/v1/app/admin/activity", params: { job_id: job.id, event_type: "landing_queue_changed" }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.fetch("events").length).to eq(1)
    expect(body.dig("events", 0, "job", "slug")).to eq(job.slug)
    expect(body.dig("events", 0, "reason_key")).to eq("pr_checks_failing")
  end

  it "sorts workflow activity with an allowlisted column" do
    admin = Factories.user
    sign_in_as(admin)

    WorkflowActivity.synchronously do
      WorkflowActivity.record!(event_type: "workflow_created", source: "spec", message: "Zulu")
      WorkflowActivity.record!(event_type: "workflow_started", source: "spec", message: "Alpha")
    end

    get "/api/v1/app/admin/activity", params: { sort: "message", direction: "asc" }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.dig("filters", "sort")).to eq("message")
    expect(body.dig("filters", "direction")).to eq("asc")
    expect(body.fetch("events").first.fetch("message")).to eq("Alpha")
  end
end
