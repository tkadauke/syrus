require "rails_helper"

RSpec.describe "API: /api/v1/admin/mysql", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }

  def auth(token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  it "is disabled by default" do
    get "/api/v1/admin/mysql", headers: auth(admin_token)

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "requires MySQL when the plugin is enabled" do
    PluginRecord.find_by!(name: "admin_mysql").update!(enabled: true)

    get "/api/v1/admin/mysql", headers: auth(admin_token)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("mysql_unavailable")
  end
end
