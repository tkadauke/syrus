require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/browser_errors", type: :request do
  before do
    allow(SyrusVersion).to receive(:current).and_return("current-sha")
  end

  it "requires an admin user" do
    Factories.user
    sign_in_as(Factories.user)

    get "/api/v1/app/admin/browser_errors"

    expect(response).to have_http_status(:forbidden)
  end

  it "returns searchable browser error events for admins" do
    admin = Factories.user
    BrowserErrorEvent.record!(
      user: admin,
      payload: {
        "occurred_at" => 5.minutes.ago.iso8601,
        "app_revision" => "current-sha",
        "fingerprint" => "map-fingerprint",
        "name" => "TypeError",
        "message" => "undefined is not an object (evaluating 'n.map')",
        "path" => "/jobs/3188",
        "recoverable" => true,
        "correlation_id" => "correlation-123",
        "component_stack_unavailable_reason" => "React did not supply a component stack",
        "error_cause" => { "name" => "ChunkError" },
        "last_interaction" => { "event_type" => "click", "target" => { "tag" => "button" } },
        "resource_timings" => [ { "name" => "/assets/lazy.js", "duration_ms" => 450 } ],
        "metadata" => {
          "resource_path" => "/assets/spa-entry.js",
          "last_completed_milestone" => "shell_loaded",
          "browser_online" => false,
          "service_worker_controlled" => true,
          "resource_timing" => { "response_status" => 503, "transfer_classification" => "network" }
        },
        "recent_api_requests" => [ { "path" => "/api/v1/app/jobs/3188", "status" => 200 } ]
      }
    )
    BrowserErrorEvent.record!(
      user: admin,
      payload: {
        "occurred_at" => 4.minutes.ago.iso8601,
        "app_revision" => "old-sha",
        "fingerprint" => "old-fingerprint",
        "message" => "old error",
        "path" => "/chats/6"
      }
    )
    sign_in_as(admin)

    get "/api/v1/app/admin/browser_errors", params: { query: "n.map", revision_scope: "current" }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.fetch("events").length).to eq(1)
    expect(body.dig("events", 0)).to include(
      "fingerprint" => "map-fingerprint",
      "message" => "undefined is not an object (evaluating 'n.map')",
      "path" => "/jobs/3188",
      "correlation_id" => "correlation-123",
      "occurrence_count" => 1,
      "burst_duration_ms" => 0
    )
    expect(body.fetch("actions")).to include(
      include("id" => "file_job", "label" => "File Job", "event_type" => "browser_error")
    )
    expect(body.dig("events", 0)).not_to have_key("recent_api_requests")
    expect(body).not_to have_key("filter_schema")
    expect(body.fetch("timeline").sum { |bucket| bucket.fetch("count") }).to eq(1)

    get "/api/v1/app/admin/browser_errors/#{body.dig("events", 0, "id")}"

    detail = response.parsed_body
    expect(detail.fetch("recent_api_requests").first).to include("path" => "/api/v1/app/jobs/3188")
    expect(detail).to include(
      "recoverable" => true,
      "component_stack_unavailable_reason" => "React did not supply a component stack",
      "error_cause" => { "name" => "ChunkError" },
      "last_interaction" => include("event_type" => "click"),
      "resource_timings" => [ include("name" => "/assets/lazy.js") ]
    )
    expect(detail.fetch("metadata")).to include(
      "resource_path" => "/assets/spa-entry.js",
      "last_completed_milestone" => "shell_loaded",
      "browser_online" => "false",
      "service_worker_controlled" => "true",
      "resource_timing" => include("response_status" => "503", "transfer_classification" => "network")
    )
  end

  it "serves stable controls separately from paginated rows" do
    admin = Factories.user
    sign_in_as(admin)

    get "/api/v1/app/admin/browser_errors/controls"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("filter_schema")).to be_present
    expect(response.parsed_body.fetch("actions")).to include(include("id" => "file_job"))
  end

  it "sorts browser error events by supported columns" do
    admin = Factories.user
    BrowserErrorEvent.record!(
      user: admin,
      payload: {
        "occurred_at" => 5.minutes.ago.iso8601,
        "app_revision" => "current-sha",
        "fingerprint" => "z",
        "message" => "zulu",
        "path" => "/z"
      }
    )
    BrowserErrorEvent.record!(
      user: admin,
      payload: {
        "occurred_at" => 4.minutes.ago.iso8601,
        "app_revision" => "current-sha",
        "fingerprint" => "a",
        "message" => "alpha",
        "path" => "/a"
      }
    )
    sign_in_as(admin)

    get "/api/v1/app/admin/browser_errors", params: { sort: "path", direction: "asc", revision_scope: "current" }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.dig("filters", "sort")).to eq("path")
    expect(body.dig("filters", "direction")).to eq("asc")
    expect(body.fetch("events").map { |event| event.fetch("path") }).to eq([ "/a", "/z" ])
  end

  it "builds the timeline from the canonical filter window instead of a flattened default" do
    admin = Factories.user
    old_event = BrowserErrorEvent.record!(
      user: admin,
      payload: {
        "occurred_at" => 2.days.ago.iso8601,
        "app_revision" => "current-sha",
        "fingerprint" => "old",
        "message" => "old error",
        "path" => "/old"
      }
    )
    BrowserErrorEvent.record!(
      user: admin,
      payload: {
        "occurred_at" => 10.minutes.ago.iso8601,
        "app_revision" => "current-sha",
        "fingerprint" => "recent",
        "message" => "recent error",
        "path" => "/recent"
      }
    )
    q = Filters::QueryParam.encode(
      "and" => [
        { "field" => "fingerprint", "op" => "is", "value" => old_event.fingerprint },
        { "field" => "revision_scope", "op" => "is", "value" => "current" }
      ]
    )
    sign_in_as(admin)

    get "/api/v1/app/admin/browser_errors", params: { q: q }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.fetch("events").map { |event| event.fetch("fingerprint") }).to eq([ "old" ])
    expect(body.fetch("timeline").sum { |bucket| bucket.fetch("count") }).to eq(1)
  end
end
