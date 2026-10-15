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

  it "rejects non-decimal thread ids before executing a kill" do
    PluginRecord.find_by!(name: "admin_mysql").update!(enabled: true)
    allow(AdminMysql::Inspector).to receive(:mysql?).and_return(true)

    post "/api/v1/admin/mysql/kill_query", params: { thread_id: "0x10" }, headers: auth(admin_token)

    expect(response).to have_http_status(:bad_request)
    expect(parse_body.dig("error", "message")).to include("positive decimal integer")
  end
end
