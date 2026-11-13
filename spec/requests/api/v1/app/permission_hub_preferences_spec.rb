require "rails_helper"

RSpec.describe "API: /api/v1/app/permission_hub_preferences", type: :request do
  let(:user) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  it "persists the selected mode on the operator" do
    sign_in_as(user)

    patch "/api/v1/app/permission_hub_preferences", params: { permission_hub_preferences: { mode: "advanced" } }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("v" => 1, "mode" => "advanced")
    expect(user.reload.permission_hub_mode).to eq("advanced")
  end

  it "rejects unknown modes" do
    user.update!(locale: "de")
    sign_in_as(user)

    patch "/api/v1/app/permission_hub_preferences", params: { permission_hub_preferences: { mode: "expert" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to eq("Wähle Einfach oder Erweitert.")
  end
end
