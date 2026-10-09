require "rails_helper"

RSpec.describe "API: /api/v1/app/desktop/api_token", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    post "/api/v1/app/desktop/api_token"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "creates and returns a token for a non-admin user who has none" do
    Factories.user # absorbs the first-user admin promotion
    member = Factories.user
    sign_in_as(member)

    post "/api/v1/app/desktop/api_token"

    expect(response).to have_http_status(:created)
    body = parse_body
    expect(body["created"]).to be(true)
    expect(body["api_token"]).to start_with("syrus_")
    expect(member.reload.api_token).to eq(body["api_token"])
  end

  it "returns the existing token without rotating it" do
    Factories.user
    member = Factories.user
    original_token = member.generate_api_token!
    sign_in_as(member)

    post "/api/v1/app/desktop/api_token"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["created"]).to be(false)
    expect(body["api_token"]).to eq(original_token)
    expect(member.reload.api_token).to eq(original_token)
  end
end
