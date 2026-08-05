require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/overview", type: :request do
  before { Rails.cache.clear }

  def cached_stuck_snapshot(items)
    Admin::StuckItemsCache::Snapshot.new(items: items, captured_at: Time.current)
  end

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
    allow(Admin::StuckItemsCache).to receive(:read).and_return(cached_stuck_snapshot([
      {
        "kind" => "running_run_without_live_worker_evidence",
        "severity" => "alarm",
        "attention_state" => "auto_repairable",
        "run_id" => run.id,
        "workflow_id" => run.step.workflow.id,
        "workflow_slug" => "WF-#{run.step.workflow.id}",
        "workflow_path" => "/jobs/#{job.id}?tab=workflows#workflow-#{run.step.workflow.id}",
        "job_id" => job.id,
        "job_path" => "/jobs/#{job.id}",
        "detail" => "Run has no live worker evidence.",
        "age_label" => "10m"
      }
    ]))
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
      "chat_scoped_events",
      "workers",
      "recurring",
      "stuck",
      "stuck_pagination",
      "stuck_snapshot"
    )
    expect(body["active_runs"]["total"]).to eq(1)
    expect(body["chat_scoped_events"]).to include(
      "window_hours" => 24,
      "by_decision" => include("no_op" => 0, "respond" => 0, "act" => 0),
      "recent" => []
    )
    expect(body["stuck_pagination"]).to include(
      "page" => 1,
      "per_page" => 50,
      "total" => 1,
      "total_pages" => 1
    )
    expect(body["stuck_snapshot"]).to include(
      "captured_at" => a_kind_of(String),
      "stale" => false
    )
    expect(body["stuck"].first).to include(
      "kind" => "running_run_without_live_worker_evidence",
      "attention_state" => "auto_repairable",
      "run_id" => run.id,
      "workflow_id" => run.step.workflow.id,
      "workflow_slug" => "WF-#{run.step.workflow.id}",
      "workflow_path" => "/jobs/#{job.id}?tab=workflows#workflow-#{run.step.workflow.id}",
      "job_id" => job.id,
      "job_path" => "/jobs/#{job.id}"
    )
  end

  it "does not show stale false Codex model-list decode failures as provider usage circuits" do
    admin = Factories.user
    job = Factories.job(user: admin, agent_provider: "codex")
    run = job.initial_run
    message = "failed to refresh available models: stream disconnected before completion: failed to decode models response: unknown variant `max`, expected none/minimal/low/medium/high/xhigh"
    run.update_columns(
      state: "failed",
      agent_provider: "codex",
      agent_outcome: "provider_usage_limit",
      finished_at: 1.minute.ago
    )
    ProviderAvailabilityEvidence.create!(
      user: admin,
      run: run,
      provider: "codex",
      account_id: CodexAccountScope.for_user(admin),
      model: "for",
      status: "exhausted",
      source: "codex_invocation_failure",
      observed_at: 1.minute.ago,
      details: { message: message }
    )
    allow(Admin::StuckItemsCache).to receive(:read).and_return(cached_stuck_snapshot([]))
    sign_in_as(admin)

    get api_v1_app_admin_overview_path

    expect(response).to have_http_status(:ok)
    reasons = parse_body.fetch("provider_circuits").map { |circuit| circuit["reason"] }
    expect(reasons).not_to include("provider usage limit exhausted for model for")
  end
end
