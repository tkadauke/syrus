require "rails_helper"

RSpec.describe "API: /api/v1/app/browser_errors", type: :request do
  let(:user) { Factories.user }

  before do
    allow(SyrusVersion).to receive(:current).and_return("browser-sha")
  end

  it "requires authentication" do
    post "/api/v1/app/browser_errors", params: { browser_error: { message: "boom", fingerprint: "abc" } }

    expect(response).to have_http_status(:unauthorized)
  end

  it "records a sanitized browser error event for the current user" do
    sign_in_as(user)

    post "/api/v1/app/browser_errors", params: {
      browser_error: {
        occurred_at: "2026-08-17T12:00:00Z",
        fingerprint: "fingerprint-123",
        name: "TypeError",
        message: "undefined is not an object (evaluating 'n.map')",
        stack: "TypeError: n.map\n    at JobDetail",
        component_stack: "at JobDetail",
        url: "https://syrus.test/jobs/3188",
        path: "/jobs/3188",
        user_agent: "Safari",
        viewport: { width: 1440, height: 900 },
        feature_flags: { coding_mode: true },
        recent_api_requests: [
          { path: "/api/v1/app/jobs/3188", status: 200, durationMs: 87.2 }
        ],
        recent_errors: [
          { message: "previous", source: "promise" }
        ],
        metadata: { boundary: "route" }
      }
    }

    expect(response).to have_http_status(:created)
    event = BrowserErrorEvent.last
    expect(response.parsed_body).to include("id" => event.id, "fingerprint" => "fingerprint-123")
    expect(event).to have_attributes(
      user: user,
      app_revision: "browser-sha",
      fingerprint: "fingerprint-123",
      name: "TypeError",
      message: "undefined is not an object (evaluating 'n.map')",
      path: "/jobs/3188"
    )
    expect(event.viewport).to include("width" => "1440", "height" => "900")
    expect(event.recent_api_requests.first).to include("path" => "/api/v1/app/jobs/3188", "status" => "200")
  end

  it "collapses a recoverable error burst into one bounded, redacted canonical event" do
    sign_in_as(user)
    base_payload = {
      app_revision: "revision-1",
      fingerprint: "react-426",
      name: "Error",
      message: "Minified React error #426",
      path: "/chats/696",
      recoverable: true,
      correlation_id: "correlation-1",
      component_stack_unavailable_reason: "React did not supply a component stack",
      error_cause: { name: "ChunkError", message: "failed?token=secret" },
      last_interaction: { event_type: "click", pathname: "/chats/shared/private-token", target: { tag: "button", test_id: "send" } },
      resource_timings: 12.times.map { |index| { name: "/assets/chunk-#{index}.js?key=secret", duration_ms: index } }
    }

    post "/api/v1/app/browser_errors", params: { browser_error: base_payload.merge(occurred_at: "2026-11-18T12:00:00Z") }
    first_id = response.parsed_body.fetch("id")
    post "/api/v1/app/browser_errors", params: {
      browser_error: base_payload.merge(
        occurred_at: "2026-11-18T12:00:19Z",
        correlation_id: "duplicate-correlation",
        component_stack: "at ChatComposer"
      )
    }

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("id" => first_id, "occurrence_count" => 2)
    expect(BrowserErrorEvent.where(fingerprint: "react-426").count).to eq(1)
    event = BrowserErrorEvent.find(first_id)
    expect(event).to have_attributes(
      occurrence_count: 2,
      burst_duration_ms: 19_000,
      component_stack: "at ChatComposer",
      correlation_id: "correlation-1"
    )
    expect(event.resource_timings.length).to eq(8)
    expect(event.error_cause.fetch("message")).not_to include("secret")
    expect(event.last_interaction.fetch("pathname")).to eq("/chats/shared/[FILTERED]")
  end

  it "does not collapse recoverable errors outside the burst window" do
    sign_in_as(user)
    payload = { fingerprint: "react-426", message: "React #426", path: "/chats/696", recoverable: true }

    post "/api/v1/app/browser_errors", params: { browser_error: payload.merge(occurred_at: "2026-11-18T12:00:00Z") }
    post "/api/v1/app/browser_errors", params: { browser_error: payload.merge(occurred_at: "2026-11-18T12:00:31Z") }

    expect(BrowserErrorEvent.where(fingerprint: "react-426").count).to eq(2)
  end

  it "retains safe startup resource evidence and aggregates a five-minute episode by user, route, revision transition, and target" do
    other_user = Factories.user
    sign_in_as(user)
    payload = {
      app_revision: "revision-2",
      name: "StartupResourceError",
      message: "SPA startup resource failed to load",
      path: "/whiteboards/7",
      metadata: {
        resource_path: "/assets/spa-entry.js?token=secret&user=private",
        resource_type: "script",
        initiator_type: "script",
        startup_phase: "startup",
        last_completed_milestone: "bootstrap_fetch_started",
        event_kind: "error",
        browser_online: false,
        service_worker_present: true,
        service_worker_controlled: true,
        revision_changed: true,
        previous_app_revision: "revision-1",
        resource_timing: {
          response_status: 503,
          duration_bucket: "1s_to_5s",
          transfer_size_bucket: "under_10kb",
          encoded_size_bucket: "10kb_to_100kb",
          transfer_classification: "network",
          raw_url: "https://user.example/private?token=secret"
        },
        arbitrary_url: "https://user.example/private?token=secret",
        body: "user-controlled content"
      }
    }

    10.times do |index|
      post "/api/v1/app/browser_errors", params: {
        browser_error: payload.merge(occurred_at: (Time.zone.parse("2026-11-21T20:00:00Z") + index * 25.seconds).iso8601)
      }
    end

    episode = BrowserErrorEvent.find(response.parsed_body.fetch("id"))
    expect(episode).to have_attributes(occurrence_count: 10, burst_duration_ms: 225_000, recoverable: true)
    expect(episode.metadata).to include(
      "resource_path" => "/assets/spa-entry.js",
      "resource_type" => "script",
      "last_completed_milestone" => "bootstrap_fetch_started",
      "browser_online" => "false",
      "service_worker_controlled" => "true"
    )
    expect(episode.metadata.fetch("resource_timing")).to include(
      "response_status" => "503",
      "encoded_size_bucket" => "10kb_to_100kb",
      "transfer_classification" => "network"
    )
    expect(episode.metadata).not_to include("arbitrary_url", "body")
    expect(episode.metadata.fetch("resource_timing")).not_to have_key("raw_url")

    post "/api/v1/app/browser_errors", params: { browser_error: payload.merge(path: "/dashboard", occurred_at: "2026-11-21T20:04:00Z") }
    sign_in_as(other_user)
    post "/api/v1/app/browser_errors", params: { browser_error: payload.merge(occurred_at: "2026-11-21T20:04:00Z") }

    expect(BrowserErrorEvent.where(name: "StartupResourceError").count).to eq(3)
  end
end
