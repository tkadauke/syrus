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
end
