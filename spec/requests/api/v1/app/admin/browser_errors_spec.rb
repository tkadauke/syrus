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
      "path" => "/jobs/3188"
    )
    expect(body.dig("events", 0, "actions")).to include(
      include("id" => "file_job", "label" => "File Job", "event_type" => "browser_error")
    )
    expect(body.dig("events", 0, "recent_api_requests").first).to include("path" => "/api/v1/app/jobs/3188")
    expect(body.fetch("timeline").sum { |bucket| bucket.fetch("count") }).to eq(1)
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
end
