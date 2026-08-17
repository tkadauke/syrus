require "rails_helper"

RSpec.describe "API: /api/v1/admin/browser_errors", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{admin_token}" }

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
end
