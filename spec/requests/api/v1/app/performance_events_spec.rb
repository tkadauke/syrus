require "rails_helper"

RSpec.describe "API: /api/v1/app/performance_events", type: :request do
  let(:user) { Factories.user }
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    allow(SyrusVersion).to receive(:current).and_return("trace-sha")
    Feature.where(slug: "performance_logging").delete_all
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Feature.clear_enabled_cache!("performance_logging")
    PerformanceLogging::Store.clear!
  end

  after do
    PerformanceLogging::Store.clear!
    Current.reset
  end

  it "401s when signed out" do
    post "/api/v1/app/performance_events", params: { performance_event: { name: "dashboard.route", duration_ms: 1200 } }

    expect(response).to have_http_status(:unauthorized)
  end

  it "records sanitized browser traces in the shared performance store" do
    sign_in_as(user)
    post "/api/v1/app/performance_events", params: {
      performance_event: {
        trace_id: "dashboard-123",
        name: "dashboard.route",
        path: "/dashboard/jobs?smart_folder_id=1",
        duration_ms: 1532.28,
        visibility_state: "visible",
        metadata: {
          subject: "job",
          view: "list",
          rows_count: 0,
          unsafe_nested: { ignored: "value" }
        },
        api_requests: [
          {
            name: "dashboard.rows",
            path: "/api/v1/app/dashboard?section=rows",
            request_id: "backend-request-1",
            duration_ms: 1411.18,
            status: 200
          }
        ]
      }
    }

    expect(response).to have_http_status(:accepted)
    event = PerformanceLogging::Store.recent(limit: 1).first
    expect(event).to include(
      "event" => PerformanceLogging::BROWSER_TRACE_EVENT,
      "app_revision" => "trace-sha",
      "name" => "dashboard.route",
      "duration_ms" => 1532.3,
      "trace_id" => "dashboard-123",
      "visibility_state" => "visible"
    )
    expect(event["metadata"]).to include(
      "subject" => "job",
      "view" => "list",
      "rows_count" => "0"
    )
    expect(event["api_requests"]).to contain_exactly(include(
      "name" => "dashboard.rows",
      "request_id" => "backend-request-1",
      "duration_ms" => 1411.2,
      "status" => 200
    ))
  end

  it "records a batch of browser traces sent as performance_events" do
    sign_in_as(user)
    post "/api/v1/app/performance_events", params: {
      performance_events: [
        { trace_id: "batch-1", name: "diff_review.parse_diff", path: "/jobs/4348?tab=review", duration_ms: 12.5, parent_id: "batch-root", interaction_id: "interaction-1" },
        { trace_id: "batch-2", name: "diff_review.syntax_highlight", path: "/jobs/4348?tab=review", duration_ms: 40.1 }
      ]
    }

    expect(response).to have_http_status(:accepted)
    events = PerformanceLogging::Store.recent(limit: 10)
    expect(events.map { |event| event["trace_id"] }).to contain_exactly("batch-1", "batch-2")
    batch_one = events.find { |event| event["trace_id"] == "batch-1" }
    expect(batch_one).to include(
      "name" => "diff_review.parse_diff",
      "parent_id" => "batch-root",
      "interaction_id" => "interaction-1"
    )
  end

  it "does not record when performance logging is disabled" do
    Feature.find_by!(slug: "performance_logging").update!(enabled: false)
    Feature.clear_enabled_cache!("performance_logging")
    sign_in_as(user)

    post "/api/v1/app/performance_events", params: { performance_event: { name: "dashboard.route", duration_ms: 1200 } }

    expect(response).to have_http_status(:accepted)
    expect(PerformanceLogging::Store.recent(limit: 10)).to be_empty
  end
end
