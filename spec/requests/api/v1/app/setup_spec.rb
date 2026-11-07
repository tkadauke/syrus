require "rails_helper"

RSpec.describe "API: /api/v1/app/setup", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "returns a JSON 401 when signed out" do
    get "/api/v1/app/setup"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "returns computed setup status for a partially configured user" do
    user = Factories.user(github_token: "ghp_test")
    sign_in_as(user)

    get "/api/v1/app/setup"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "state" => "first_admin",
      "next_step" => "configure_credentials",
      "credentials_configured" => false
    )
    expect(body.dig("credential_status", "github_pat")).to eq(true)
    expect(body.dig("readiness", "checks")).to be_an(Array)
  end
end
