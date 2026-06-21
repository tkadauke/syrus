require "rails_helper"

RSpec.describe "API: /api/v1/app/layout_version", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "updates the signed-in user's layout version" do
    user = Factories.user(layout_version: "v1")
    sign_in_as(user)

    patch "/api/v1/app/layout_version", params: { layout_version: "v2" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("layout_version" => "v2")
    expect(user.reload.layout_version).to eq("v2")
  end

  it "rejects unknown layout versions" do
    user = Factories.user(layout_version: "v1")
    sign_in_as(user)

    patch "/api/v1/app/layout_version", params: { layout_version: "v3" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(user.reload.layout_version).to eq("v1")
  end

  it "requires authentication" do
    Factories.user

    patch "/api/v1/app/layout_version", params: { layout_version: "v2" }

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end
end
