require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/settings", type: :request do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/settings"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/settings"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns editable settings and an empty clearable secrets list" do
    sign_in_as(admin)
    AppSetting.current.update!(signups_open: true)

    get "/api/v1/app/admin/settings"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("settings", "signups_open")).to be true
    expect(body.dig("settings", "clearable_secrets")).to eq([])
  end

  it "updates signups_open" do
    sign_in_as(admin)

    patch "/api/v1/app/admin/settings", params: {
      app_setting: {
        signups_open: true
      }
    }

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.signups_open).to be true
    expect(parse_body["message"]).to eq("Settings updated.")
  end

  it "rejects unknown app secret names" do
    sign_in_as(admin)

    post "/api/v1/app/admin/settings/clear_secret", params: { secret: "github_app_id" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("unknown_secret")
  end
end
