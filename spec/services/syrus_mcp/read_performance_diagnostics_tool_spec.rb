require "rails_helper"

RSpec.describe SyrusMcp::ReadPerformanceDiagnosticsTool do
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "tkadauke", name: "syrus") }
  let(:run) { Factories.job(repository: repository, user: user).initial_run }

  def payload_from(response)
    JSON.parse(response.content.first[:text])
  end

  def append_event(**attrs)
    attrs = attrs.stringify_keys
    PerformanceLogging::Store.append(
      {
        "event" => PerformanceLogging::SLOW_REQUEST_EVENT,
        "occurred_at" => Time.current.iso8601(6),
        "app_revision" => "new-sha",
        "method" => "GET",
        "path" => "/api/v1/app/jobs?token=super-secret",
        "controller" => "Api::V1::App::JobsController",
        "action" => "show",
        "duration_ms" => 1_500.0,
        "sql_count" => 2,
        "sql_duration_ms" => 250.0,
        "top_sql_fingerprints" => [
          {
            "fingerprint" => "SELECT * FROM jobs WHERE id = ?",
            "sample_sql" => "SELECT * FROM jobs WHERE token = 'super-secret'",
            "name" => "Job Load",
            "count" => 1,
            "total_duration_ms" => 250.0,
            "max_duration_ms" => 250.0
          }
        ]
      }.merge(attrs)
    )
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    allow(SyrusVersion).to receive(:current).and_return("new-sha")
    Feature.where(slug: "performance_logging").delete_all
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Feature.clear_enabled_cache!("performance_logging")
    Current.reset
    PerformanceLogging::Store.clear!
  end

  after do
    Current.reset
    PerformanceLogging::Store.clear!
  end

  it "returns sanitized summaries and metadata without raw events by default" do
    append_event

    response = described_class.call(server_context: { run_id: run.id })

    expect(response).not_to be_error
    payload = payload_from(response)
    expect(payload).to include(
      "enabled" => true,
      "current_revision" => "new-sha",
      "revision_scope" => "current"
    )
    expect(payload["storage"]).to include("max_events" => PerformanceLogging::Store::MAX_EVENTS)
    expect(payload["thresholds"]).to include("slow_request_ms", "slow_sql_ms", "slow_phase_ms")
    expect(payload).not_to have_key("events")
    expect(payload.dig("summaries", "slow_requests").first).to include(
      "path" => "/api/v1/app/jobs",
      "count" => 1
    )
    expect(payload.dig("summaries", "sql_fingerprints").first).to include(
      "fingerprint" => "SELECT * FROM jobs WHERE id = ?",
      "count" => 1
    )
    expect(payload.to_json).not_to include("super-secret", "sample_sql")
  end

  it "includes bounded sanitized raw recent events when requested" do
    append_event(path: "/first?password=secret")
    append_event(path: "/second?api_key=secret")

    response = described_class.call(server_context: { run_id: run.id }, limit: 1, include_events: true)

    expect(response).not_to be_error
    payload = payload_from(response)
    expect(payload["events"].size).to eq(1)
    expect(payload.dig("events", 0, "path")).to eq("/second")
    expect(payload.to_json).not_to include("sample_sql", "password=secret", "api_key=secret")
  end

  it "redacts secret-bearing path segments from raw events and summaries" do
    append_event(path: "/password/super-secret/jobs/token=other-secret")

    response = described_class.call(server_context: { run_id: run.id }, include_events: true)

    expect(response).not_to be_error
    payload = payload_from(response)
    expect(payload.dig("events", 0, "path")).to eq("/password/[REDACTED]/jobs/[REDACTED]")
    expect(payload.dig("summaries", "slow_requests", 0, "path")).to eq("/password/[REDACTED]/jobs/[REDACTED]")
    expect(payload.to_json).not_to include("super-secret", "other-secret")
  end

  it "matches admin performance payload revision-scope filtering" do
    append_event(app_revision: "old-sha", path: "/old")
    append_event(app_revision: "new-sha", path: "/new")

    current_response = described_class.call(server_context: { run_id: run.id }, revision_scope: "current", include_events: true)
    all_response = described_class.call(server_context: { run_id: run.id }, revision_scope: "all", include_events: true)

    expect(payload_from(current_response)["events"].map { |event| event["path"] }).to eq([ "/new" ])
    expect(payload_from(all_response)["events"].map { |event| event["path"] }).to contain_exactly("/old", "/new")
  end

  it "does not append performance events while reading diagnostics" do
    append_event
    before_events = PerformanceLogging::Store.recent(limit: 10)

    described_class.call(server_context: { run_id: run.id }, include_events: true)

    expect(PerformanceLogging::Store.recent(limit: 10)).to eq(before_events)
  end

  it "rejects a normal non-Syrus repository even when called directly" do
    normal_run = Factories.job.initial_run

    response = described_class.call(server_context: { run_id: normal_run.id })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("only available for Syrus repositories")
  end

  it "rejects direct calls from non-implementation workflow roles" do
    review_step = Step.create!(workflow: run.workflow, kind: "adversarial_review", position: 99)
    review_run = Run.create!(job: run.job, user: run.user, step: review_step, trigger_kind: "initial")

    response = described_class.call(server_context: { run_id: review_run.id })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not_authorized")
  end
end
