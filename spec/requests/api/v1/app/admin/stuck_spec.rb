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
      "kind" => "running_run_without_live_worker_evidence",
      "severity" => "warn",
      "attention_state" => "operator_action_required",
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
    expect(parse_body["items"].first["repair_plan"]).to include("action" => "capture_run_diagnostics")
  end

  it "surfaces a stale queued retry Run even when the Workflow has previous Runs" do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
    sign_in_as(admin)
    job = Factories.job(user: admin)
    workflow = job.latest_workflow
    step = workflow.first_step
    previous_run = job.initial_run
    previous_run.update_columns(state: "failed", finished_at: 6.minutes.ago)
    retry_run = step.runs.create!(
      job: job,
      user: admin,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      state: "queued",
      created_at: 5.minutes.ago,
      updated_at: 5.minutes.ago
    )
    clear_solid_queue_test_tables!
    workflow.update_columns(state: "running", started_at: 6.minutes.ago)
    step.update_columns(state: "queued")

    get "/api/v1/app/admin/stuck"

    expect(response).to have_http_status(:ok)
    item = parse_body["items"].find { |row| row["run_id"] == retry_run.id }
    expect(item).to include(
      "kind" => "queued_run_without_queue_claim",
      "attention_state" => "auto_repairable",
      "run_id" => retry_run.id,
      "workflow_id" => workflow.id,
      "job_id" => job.id
    )
    expect(item["repair_plan"]).to include("action" => "reenqueue_run", "auto_executable" => true)
  ensure
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  it "surfaces running jobs without an active workflow" do
    sign_in_as(admin)
    job = Factories.job_record(user: admin, state: "running", updated_at: 10.minutes.ago)

    get "/api/v1/app/admin/stuck"

    expect(response).to have_http_status(:ok)
    expect(parse_body["items"]).to include(include(
      "kind" => "job_without_active_workflow",
      "severity" => "alarm",
      "attention_state" => "operator_action_required",
      "job_id" => job.id,
      "job_state" => "running",
      "force_fail_path" => "/api/v1/app/jobs/#{job.id}/force_fail"
    ))
  end
end
