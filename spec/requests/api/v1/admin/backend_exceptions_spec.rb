require "rails_helper"

RSpec.describe "API: /api/v1/admin/backend_exceptions", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:admin_token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{admin_token}" }

  it "requires an API token" do
    get "/api/v1/admin/backend_exceptions"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns backend exceptions to admin API clients" do
    BackendExceptionEvent.create!(
      occurred_at: Time.current,
      source: "action_controller",
      exception_class: "NoMethodError",
      message: "undefined method map for nil",
      path: "/jobs/3188",
      request_id: "req-123"
    )

    get "/api/v1/admin/backend_exceptions", headers: auth

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("events", 0)).to include(
      "exception_class" => "NoMethodError",
      "message" => "undefined method map for nil",
      "path" => "/jobs/3188",
      "request_id" => "req-123"
    )
  end
end
