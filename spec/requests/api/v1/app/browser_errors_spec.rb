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
end
