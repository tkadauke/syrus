require "rails_helper"

RSpec.describe "API: /api/v1/app/theme", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "updates the signed-in user's theme" do
    user = Factories.user(theme: "light")
    sign_in_as(user)

    patch "/api/v1/app/theme", params: { theme: "dark" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("theme" => "dark")
    expect(user.reload.theme).to eq("dark")
  end

  it "rejects unknown themes" do
    user = Factories.user(theme: "light")
    sign_in_as(user)

    patch "/api/v1/app/theme", params: { theme: "system" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(user.reload.theme).to eq("light")
  end

  it "requires authentication" do
    Factories.user

    patch "/api/v1/app/theme", params: { theme: "dark" }

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end
end
