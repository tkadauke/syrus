require "rails_helper"

RSpec.describe "API: /api/v1/admin/whoami", type: :request do
  let(:admin) { Factories.user(email_address: "admin@example.com", name: "Admin Person") }
  let(:token) { admin.generate_api_token! }

  it "returns the token owner" do
    get "/api/v1/admin/whoami", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.fetch("user")).to include(
      "id" => admin.id,
      "email_address" => "admin@example.com",
      "name" => "Admin Person",
      "admin" => true
    )
  end
end
