require "rails_helper"
require "rake"

RSpec.describe "API: /api/v1/admin/browser_errors", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{admin_token}" }

  before(:all) do
    Rails.application.load_tasks
  end

  it "requires an API token" do
    get "/api/v1/admin/browser_errors"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns browser errors to admin API clients" do
    BrowserErrorEvent.record!(
      user: admin,
      payload: {
        "fingerprint" => "browser-api-fingerprint",
        "message" => "frontend crashed",
        "path" => "/jobs/3214"
      }
    )

    get "/api/v1/admin/browser_errors", headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("events", 0)).to include(
      "fingerprint" => "browser-api-fingerprint",
      "message" => "frontend crashed",
      "path" => "/jobs/3214"
    )
  end

  it "filters browser errors by event id" do
    first = BrowserErrorEvent.record!(
      user: admin,
      payload: {
        "fingerprint" => "first",
        "message" => "first frontend crash"
      }
    )
    BrowserErrorEvent.record!(
      user: admin,
      payload: {
        "fingerprint" => "second",
        "message" => "second frontend crash"
      }
    )

    get "/api/v1/admin/browser_errors?id=#{first.id}&revision_scope=all", headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("events").map { |event| event.fetch("id") }).to eq([ first.id ])
  end

  it "uses indexed diagnostic fields for query searches when available" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS browser_error_fts")
    SyrusSearchDatabaseTasks.prepare!
    event = BrowserErrorEvent.record!(
      user: admin,
      payload: {
        "fingerprint" => "indexed-stack",
        "message" => "frontend crash",
        "stack" => "at DeepJobWorkflowPanel.render"
      }
    )
    BrowserErrorIndex.upsert(event)

    get "/api/v1/admin/browser_errors?query=DeepJobWorkflowPanel&revision_scope=all", headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("events").map { |row| row.fetch("id") }).to eq([ event.id ])
  end
end
