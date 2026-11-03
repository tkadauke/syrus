require "rails_helper"

RSpec.describe "API: /api/v1/admin/settings", type: :request do
  let!(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { Factories.user.generate_api_token! }

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }

  it "returns max_concurrent_agent_runs and other execution gates with registry metadata" do
    AppSetting.current.update!(max_concurrent_agent_runs: 7)

    get "/api/v1/admin/settings", headers: auth

    expect(response).to be_successful
    setting = JSON.parse(response.body).dig("settings", "max_concurrent_agent_runs")
    expect(setting).to include("value" => 7, "type" => "integer", "zero_means" => a_kind_of(String))
  end

  it "never returns secret settings" do
    body = (get "/api/v1/admin/settings", headers: auth) && JSON.parse(response.body)

    secret_keys = AppSettingRegistry.definitions.select(&:secret).map { |definition| definition.key.to_s }
    expect(body["settings"].keys & secret_keys).to be_empty
  end

  it "401s without a token and 403s for a non-admin" do
    get "/api/v1/admin/settings"
    expect(response).to have_http_status(:unauthorized)

    get "/api/v1/admin/settings", headers: auth(non_admin_token)
    expect(response).to have_http_status(:forbidden)
  end
end
