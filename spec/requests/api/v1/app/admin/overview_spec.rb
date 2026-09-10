require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/overview", type: :request do
  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before do
    clear_solid_queue_test_tables!
    Rails.cache.clear
  end

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
    allow(Admin::StuckItemsCache).to receive(:read).and_call_original
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
      "recurring"
    )
    expect(body["active_runs"]["total"]).to eq(1)
    expect(body["recurring"]).to include("count" => 0)
    expect(body["recurring"]).not_to have_key("overdue")
    expect(body).not_to have_key("resource_admission")
    expect(body).not_to have_key("chat_scoped_events")
    expect(body).not_to include("stuck", "stuck_pagination", "stuck_snapshot")
    expect(Admin::StuckItemsCache).not_to have_received(:read)
  end

  it "keeps the default overview query budget off recurring execution history" do
    admin = Factories.user
    task = SolidQueue::RecurringTask.create!(
      key: "poll_repositories",
      class_name: "PollAllRepositoriesJob",
      schedule: "*/5 * * * *",
      static: true,
      created_at: Time.current,
      updated_at: Time.current
    )
    recurring_job = SolidQueue::Job.create!(
      class_name: "PollAllRepositoriesJob",
      queue_name: "polling",
      priority: 0,
      arguments: { "arguments" => [] },
      created_at: 20.minutes.ago,
      updated_at: 20.minutes.ago,
      finished_at: 19.minutes.ago
    )
    SolidQueue::RecurringExecution.create!(
      task_key: task.key,
      run_at: 20.minutes.ago,
      job: recurring_job,
      created_at: 20.minutes.ago
    )
    sign_in_as(admin)

    metrics = capture_performance_budget { get api_v1_app_admin_overview_path }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("recurring")).to eq("count" => 1)
    expect_performance_budget(
      metrics,
      max_sql: 32,
      max_payload_bytes: 80.kilobytes,
      forbidden_sql: [ /\bFROM "?solid_queue_recurring_executions"?/i ]
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

  it "keeps raw worker health metrics out of the overview payload" do
    admin = Factories.user
    InstanceVersion.create!(
      hostname: "worker-a",
      role: "worker",
      version: "abc123",
      started_at: 5.minutes.ago,
      last_heartbeat_at: 10.seconds.ago
    )
    WorkerHostHealthSample.create!(
      hostname: "worker-a",
      role: "worker",
      version: "abc123",
      observed_at: 1.minute.ago,
      cpu_used_percent: 42,
      raw_metrics: { "large" => "payload" }
    )
    allow(Admin::StuckItemsCache).to receive(:read).and_return(cached_stuck_snapshot([]))
    sign_in_as(admin)

    get api_v1_app_admin_overview_path

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("worker_health", "hosts")).to eq([])
    sample = body.dig("worker_health", "current", 0, "sample")
    expect(sample).to include("cpu_used_percent" => 42.0)
    expect(sample).not_to have_key("raw_metrics")
  end

  it "returns resource admission diagnostics only when requested for the subpage" do
    admin = Factories.user
    allow(Admin::StuckItemsCache).to receive(:read).and_return(cached_stuck_snapshot([]))
    sign_in_as(admin)

    get api_v1_app_admin_overview_path, params: { page: "resource_admission" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["resource_admission"]).to include(
      "windows" => include("recent_hours" => 24, "delayed_hours" => 6),
      "active_consumers" => [],
      "recent_top_consumers" => []
    )
    expect(parse_body).not_to have_key("chat_scoped_events")
  end

  it "returns scoped chat event diagnostics only when requested for the subpage" do
    admin = Factories.user
    allow(Admin::StuckItemsCache).to receive(:read).and_return(cached_stuck_snapshot([]))
    sign_in_as(admin)

    get api_v1_app_admin_overview_path, params: { page: "scoped_chat_events" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["chat_scoped_events"]).to include(
      "window_hours" => 24,
      "by_decision" => include("no_op" => 0, "respond" => 0, "act" => 0),
      "recent" => []
    )
    expect(parse_body).not_to have_key("resource_admission")
  end
end
