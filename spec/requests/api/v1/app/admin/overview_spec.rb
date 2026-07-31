require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/overview", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get api_v1_app_admin_overview_path

    expect(response).to have_http_status(:unauthorized)
    expect(response.media_type).to eq("application/json")
    expect(parse_body).to eq(
      "error" => {
        "code" => "unauthorized",
        "message" => "Sign in to use the app API."
      }
    )
  end

  it "403s with a JSON error for non-admin users" do
    Factories.user
    user = Factories.user
    sign_in_as(user)

    get api_v1_app_admin_overview_path

    expect(response).to have_http_status(:forbidden)
    expect(response.media_type).to eq("application/json")
    expect(parse_body).to eq(
      "error" => {
        "code" => "forbidden",
        "message" => "Admin access required."
      }
    )
  end

  it "returns the admin overview rollup for admin users" do
    admin = Factories.user
    job = Factories.job(user: admin)
    run = job.initial_run
    run.update_columns(state: "running", started_at: 10.minutes.ago, last_heartbeat_at: 10.minutes.ago)
    sign_in_as(admin)

    get api_v1_app_admin_overview_path

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "active_runs",
      "queued_runs",
      "recent_failures_24h",
      "github_rate_limits",
      "github_api_blocked_users",
      "agent_session_capture_rate",
      "worker_health",
      "workers",
      "recurring",
      "stuck"
    )
    expect(body["active_runs"]["total"]).to eq(1)
    expect(body["stuck"].first).to include(
      "kind" => "running_run_without_live_worker_evidence",
      "attention_state" => "operator_action_required",
      "run_id" => run.id,
      "workflow_id" => run.step.workflow.id,
      "workflow_slug" => "WF-#{run.step.workflow.id}",
      "workflow_path" => "/jobs/#{job.id}?tab=workflows#workflow-#{run.step.workflow.id}",
      "job_id" => job.id,
      "job_path" => "/jobs/#{job.id}"
    )
  end
end
