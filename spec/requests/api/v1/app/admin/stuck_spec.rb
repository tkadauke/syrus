require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/stuck", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/stuck"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/stuck"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns stuck items for admin users" do
    sign_in_as(admin)
    job = Factories.job(user: admin)
    run = job.initial_run
    run.update_columns(state: "running",
                       started_at: 10.minutes.ago,
                       last_heartbeat_at: 10.minutes.ago)

    get "/api/v1/app/admin/stuck"

    expect(response).to have_http_status(:ok)
    expect(parse_body["items"].first).to include(
      "kind" => "stale_heartbeat",
      "severity" => "warn",
      "run_id" => run.id,
      "workflow_id" => run.step.workflow.id,
      "workflow_slug" => "WF-#{run.step.workflow.id}",
      "workflow_path" => "/jobs/#{job.id}?tab=workflows#workflow-#{run.step.workflow.id}",
      "workflow_trigger_kind" => "initial",
      "step_kind" => "prepare",
      "job_id" => job.id,
      "job_state" => job.reload.state,
      "job_path" => "/jobs/#{job.id}",
      "force_fail_path" => "/api/v1/app/jobs/#{job.id}/force_fail",
      "has_transcript" => false
    )
  end

  it "surfaces running jobs without an active workflow" do
    sign_in_as(admin)
    job = Factories.job_record(user: admin, state: "running", updated_at: 10.minutes.ago)

    get "/api/v1/app/admin/stuck"

    expect(response).to have_http_status(:ok)
    expect(parse_body["items"]).to include(include(
      "kind" => "job_without_active_workflow",
      "severity" => "alarm",
      "job_id" => job.id,
      "job_state" => "running",
      "force_fail_path" => "/api/v1/app/jobs/#{job.id}/force_fail"
    ))
  end
end
