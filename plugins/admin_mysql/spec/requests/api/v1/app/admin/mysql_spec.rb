require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/mysql", type: :request do
  let(:admin) { Factories.user(admin: true) }

  def parse_body = JSON.parse(response.body)

  it "is disabled by default" do
    sign_in_as(admin)

    get "/api/v1/app/admin/mysql"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "requires MySQL when the plugin is enabled" do
    sign_in_as(admin)
    PluginRecord.find_by!(name: "admin_mysql").update!(enabled: true)

    get "/api/v1/app/admin/mysql"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("mysql_unavailable")
  end

  it "does not advertise the admin page on SQLite" do
    sign_in_as(admin)
    PluginRecord.find_by!(name: "admin_mysql").update!(enabled: true)

    get "/api/v1/app/admin/plugin_pages"

    expect(response).to have_http_status(:ok)
    page_ids = parse_body.fetch("pages").map { |page| page.fetch("id") }
    expect(page_ids).not_to include("admin_mysql.mysql")
  end

end
