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
      "complete" => false,
      "next_step" => "credentials"
    )
    expect(body.dig("credentials", "github_token")).to eq(true)
    expect(body.dig("system", "ready")).to eq(true)
    expect(body.dig("credentials", "selected_agent_provider_configured")).to eq(false)
    expect(body.dig("github_app", "explanation")).to include("falls back to your GitHub PAT")
    expect(body.dig("paths", "setup_path")).to eq(setup_path)
  end
end
